# Security guidance — usrmanage

Operator and deployment guidance. Audit history (checked / fixed / accepted / open): [security-review.md](security-review.md). Threat model: [threat-model.md](threat-model.md).

## Operational audit claim

Usrmanage writes a **compact operational audit log** to `/var/log/usrmanage/audit.log` and mirrors lines to syslog (`logger -t usrmanage`).

This is **not** compliance-grade evidence:

- Root on the device can truncate or forge the local file.
- Rotation may drop older events.
- For retention, forward syslog to a remote collector (see below).

## TLS for LuCI password changes

In hardened / government deployments:

1. Serve LuCI only over **HTTPS** (or an equivalent encrypted management channel).
2. Do not expose LuCI password APIs on cleartext HTTP from untrusted networks.
3. Prefer management VLAN / VPN access control in addition to TLS.

This package cannot enforce device TLS configuration; operators must.

## Remote syslog (deployment guidance)

Example (device-side): ensure `logd` / `syslog-ng` / remote relay receives `usrmanage` tagged lines. Exact UCI varies by image; goal is off-box retention of grant/remove/role events.

## Password handling

| Path | Behavior |
|------|----------|
| CLI | TTY prompt or `--password-fd N` — never argv |
| LuCI | Password field in ubus call → rpcd pipes to CLI `--password-fd 0` |
| Audit / syslog | Never contains password material |
| Policy (factory default) | OpenWrt preset: min length 8, not equal to username. Stricter presets (Standard, Strict) and toggles apply after an operator saves a new policy |

Passwords must be **single-line and free of control characters**. The CLI reads the password fd and rejects any value with an embedded (or trailing) newline or a control character with an explicit `password_policy:multi_line` / `password_policy:control_char` error — it never silently truncates. The rpcd path applies the same rejection before piping to the CLI. Valid single-line passwords are unaffected.

Do **not** copy stock `luci setPassword` `echo \| passwd` shell interpolation patterns for new code.

## Environment override gate

Account-file path and behavior overrides (`USRMANAGE_PASSWD`, `USRMANAGE_SHADOW`, `USRMANAGE_GROUP`, `USRMANAGE_REGISTRY`, `USRMANAGE_SUDOERS`, `USRMANAGE_UID_FLOOR`, `USRMANAGE_HOME_ROOT`, plus the infra paths `ETC`/`AUDIT_DIR`/`AUDIT`/`LOCK`/`INCOMPLETE`) are **ignored** unless `USRMANAGE_TEST_OVERRIDES=1` is set.

- `USRMANAGE_TEST_OVERRIDES=1` is a **test-only** switch: it is set by the host test harness (`scripts/smoke-host.sh` and the `tests/*.sh` stages). It must never be set in production environments, init scripts, or sudoers env_reset overrides.
- In production the packaged defaults are forced, so a stray `USRMANAGE_*` override can never redirect root writes to arbitrary paths.

## Sudo / wheel (intentional)

`/etc/sudoers.d/usrmanage` grants:

```
%wheel ALL=(ALL:ALL) ALL
```

with password required (no NOPASSWD). **Admin role means full root via sudo.** Document this for auditors and customers.

**Invariant: never grant `usrmanage` (or the shell script behind it) via a NOPASSWD sudoers rule.** The password gate is what makes `%wheel` require an explicit credential; a NOPASSWD rule would let any member of the allowed set run `usrmanage` as root without a password, and combined with the environment-override gate below that becomes arbitrary root file rewrite.

## LuCI login lifecycle (opt-in)

Managed users default to **SSH-only**. Opt-in LuCI logins created by usrmanage:

- Always use `$p$username` (UNIX shadow). Empty or locked (`!`/`*`) shadow hashes are refused — rpcd treats an empty hash as **any password**.
- Are marked `option usrmanage '1'` and only mutated when marker + registry + `$p$` match.
- **Readonly owned:** session + health ACL only — Device health menu; no user table, wireless keys, or config backups over ubus.
- **Admin owned (default app scope):** User Management ACL only (same as pre-0.1.7). **Full LuCI (`*`)** only with explicit `--scope full` / admin scope control — never auto-granted on upgrade.
- Revoke the target user's ubus sessions on disable, role change, delete, and password change (live sessions keep ACLs until destroyed).

The **no-secrets guarantee applies to LuCI/ubus sessions only.** A readonly account with SSH can still reach K1–K7 classes via the shell with the same UNIX password; that residual is documented, not hidden.

**LuCI-login gaps (2026-08-12 audit) — resolved:** the controls below are now in force; the manual workarounds are no longer needed.

- [#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) — **resolved** (fail-closed parser): `um_rpcd_config_parsable` rejects non-canonical `config login` sections (indented, abbreviated, quoted-type, quoted option/list keys, trailing `#`). `set-luci-login --disable` / `del` then **fail closed without mutating the login** — the section remains until the configuration is repaired and the operation is retried. See the LuCI login lifecycle controls in [security-review.md](security-review.md).
- [#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) — **resolved** (mode-preserving rewrite): `um_rpcd_atomic_replace` captures the destination mode (default `0600`) and the rollback path restores `0600`, so rewrites no longer widen `/etc/config/rpcd`.
- [#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105) — **resolved** (same-role revoke): after `um_luci_login_sync_acls` in `set-role` (including same-role), `_um_set_role_revoke` runs fail-closed and revokes live sessions.

Enabling web login makes the SSH/sudo password reachable via unauthenticated `session.login` (often over HTTP). Prefer HTTPS and a management VLAN/VPN. Write ACL on `luci-app-usrmanage` remains root-equivalent.

Manual `luci-app-acl` logins (including separate hash passwords) stay out of scope and are never overwritten.

## Package lifecycle

- Upgrade must not delete managed users or remove `wheel`.
- `/etc/sudoers.d/usrmanage` and `/etc/usrmanage/users` are **conffiles**.
- Uninstall does not purge managed users by default.


## Account file write safety (v0.1.3+)

Mutations run under `flock`. Multi-file create/delete/set-role snapshots passwd/shadow/group/registry/rpcd and restores on failure. Atomic replaces use `umask 077` temps, then fixed modes (`shadow` 0600, `passwd`/`group` 0644) and `chown 0:0` before `mv`. Interactive CLI password prompts disable echo: `stty -echo` when `stty` is available (fail closed on error), otherwise BusyBox ash/bash `read -s` (stock OpenWrt has no `stty` applet). Non-interactive use remains `--password-fd`.

Rollback is EXIT-trap based: it covers process crashes and `um_die` paths, but **not SIGKILL or power loss**. After a hard kill, `doctor` reports any orphaned `usrmanage-tx.*` snapshot directory so the operator can restore manually (accepted residual, [#96](https://github.com/lucas-albers-lz4/usrmanage/issues/96)). Snapshots live in `${TMPDIR:-/tmp}` (tmpfs) — manual recovery applies only if the snapshot survives until the operator acts. `um_mut_del` additionally commits before `um_registry_del` (purge may have removed the home); the post-commit registry window is guarded by the `incomplete` marker, not the snapshot.

BusyBox `flock` has no wait-timeout (`-w`). A stuck holder blocks concurrent manage commands indefinitely until the holder exits or the device reboots; `doctor` can surface lock-held state. See [security-review.md](security-review.md) (accepted BusyBox constraint).

## Binary feed trust

Installing from the [signed feed](binary-feed.md) bootstraps trust on first use. The operator downloads the signing public key over HTTPS from the same origin that serves the packages. The key fingerprints are published for out-of-band verification. See the key table in [binary-feed.md](binary-feed.md) and the [README](../README.md) ([#64](https://github.com/lucas-albers-lz4/usrmanage/issues/64), fixed in [PR #81](https://github.com/lucas-albers-lz4/usrmanage/pull/81)). The install snippets verify the SHA-256 before trusting the key. Prefer installing on a network you trust, and keep `ca-bundle` present so the HTTPS fetch is actually validated.

## Future reviews

Procedure, scope map, proof classes (`host` / `lab` / `manual`), and open findings live in [security-review.md](security-review.md) — that ledger is the single source of truth for review state. Do not treat host DRY_RUN stubs as proof of lab-class controls (e.g. live ubus session revoke). Prevention gates: [security-prevention-plan.md](security-prevention-plan.md). Latest LuCI-login deep dive: [security-audit-luci-login-2026-08-12.md](security-audit-luci-login-2026-08-12.md).
