# Security guidance — usrmanage

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

Passwords must be **single-line**. The CLI reads one line via `read -r` from the password fd (or TTY); an embedded newline truncates the value.

Do **not** copy stock `luci setPassword` `echo \| passwd` shell interpolation patterns for new code.

## Sudo / wheel (intentional)

`/etc/sudoers.d/usrmanage` grants:

```
%wheel ALL=(ALL:ALL) ALL
```

with password required (no NOPASSWD). **Admin role means full root via sudo.** Document this for auditors and customers.

## LuCI ACL wiring (no auto login in v1)

Use `luci-app-acl` / `rpcd` login with `$p$username` for UNIX shadow passwords:

| LuCI principal | ACL grant |
|----------------|-----------|
| Readonly operator | `luci-app-usrmanage` **read** only |
| Admin operator | `luci-app-usrmanage` **read + write** |

## Package lifecycle

- Upgrade must not delete managed users or remove `wheel`.
- `/etc/sudoers.d/usrmanage` and `/etc/usrmanage/users` are **conffiles**.
- Uninstall does not purge managed users by default.


## Account file write safety (v0.1.3+)

Mutations run under `flock`. Multi-file create/delete snapshots passwd/shadow/group/registry and restores on failure. Atomic replaces use `umask 077` temps, then fixed modes (`shadow` 0600, `passwd`/`group` 0644) and `chown 0:0` before `mv`. Interactive `passwd` prompts may echo if `stty` is absent on stock images; prefer `--password-fd`.
