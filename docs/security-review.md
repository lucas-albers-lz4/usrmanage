# Security audit ledger — usrmanage

Record of what was **checked**, **proven**, **fixed**, **accepted**, and **still open** (open items are candidates pending review/fix).
Start here for future security / integrity reviews so prior work is not re-done blindly.

Operator guidance: [security.md](security.md). Threat model: [threat-model.md](threat-model.md).

## Three goals

| Goal | Meaning |
|------|---------|
| **Exploit** | Injection, privilege escalation, password leakage, ACL bypass, audit-field injection |
| **Data corruption / bricked login** | Races, crash mid-mutation, last-admin lockout, sudoers/registry loss on upgrade, stuck operator lock |
| **Supply chain** | Anything that changes what an operator installs as root: workflow injection, signing-key handling, unpinned build/sign tooling, feed trust bootstrap |

## Surface coverage map

Every reviewable surface, where it lives, and when it was last looked at. **Update the date and findings columns in the same PR as the review.** Without this table the first two review passes both re-read the same CLI and rpcd code while the release pipeline went unexamined until 2026-08-09; the oldest date here is where the next pass should start.

| Surface | Where | Last reviewed | Open findings |
|---------|-------|---------------|---------------|
| CLI + shared library | `openwrt-feed/usrmanage/files/usr/sbin/usrmanage`, `files/usr/lib/usrmanage/usrmanage-lib.sh`, `usrmanage-luci-login.sh`, `usrmanage-health.sh` | 2026-08-22 (#156 diagnostic-rpc 9-set) | none |
| rpcd plugin + ACL | `openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage`, `root/usr/share/rpcd/acl.d/` | 2026-08-23 (#158 `show` write-ACL gate) | none |
| LuCI view | `openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js` | 2026-08-20 (no scope picker; view-only UM) | none (XSS / expect convention re-confirmed) |
| On-device install surface | package Makefiles, `files/etc/` (sudoers, uci-defaults, UCI config, registry), luci-app `91-usrmanage-readonly-observer` / `92-usrmanage-diagnostic-rpc`, usrmanage `91-usrmanage-diagnostic-rpc` | 2026-08-22 (migrate → diagnostic 9-set) | none |
| CI workflows | `.github/workflows/`, `.github/dependabot.yml` | 2026-08-15 (#126 peaceiris pin checklist) | none |
| Release + signing | `scripts/publish-packages.sh`, `scripts/lib/feed-keys.sh`, `scripts/lib/feed-publish.sh`, `scripts/validate-feed-keys.sh` | 2026-08-18 (R7 layout: sdk-export + sibling mounts) | none |
| Build inputs (SDK, feeds) | `scripts/lib/sdk-matrix.sh`, `scripts/feeds.lock/`, `docker-compose.yml` | 2026-08-18 (R7 layout: `sdk-export` service, no workspace mount) | none |
| Operator trust bootstrap | `docs/binary-feed.md`, `packages-repo/README.md`, published feed keys | 2026-08-12 (#117) | none |
| QEMU lab + e2e | `scripts/qemu-*.sh`, `tests/e2e/`, `playwright.config.js` | 2026-08-22 (#156 page RPC allow + deny luci-base/getWirelessDevices; Playwright 4/4) | none open (I3 accepted residual) — fixtures remain lab-only by design |

## How to re-verify (current gates)

| Command | What it covers |
|---------|----------------|
| `./scripts/smoke-host.sh` | shellcheck, package layout, link check, validators, mutators-under-lock, rpcd argv (password-safe stub), busybox fallback, luci-login + health schema, theme/i18n/parity |
| `python3 scripts/z3-verify.py --full` | Formal proof of username / actor grammars (empty, length, deny-list, injection alphabet) |
| `./scripts/qemu-smoke-usrmanage.sh` | Live OpenWrt guest: doctor → mutators → session revoke → **readonly diagnostic** (page RPCs `network.interface dump` / `uci get`/`changes` allow via diagnostic-rpc; still deny `luci-base` + `getWirelessDevices`; uci write / add / shadow / logs deny; list+health allow) → **admin full** wireless get → `--scope` rejected → demote leftover SID dead → LuCI/ubus |
| `gh api repos/:owner/:repo/code-scanning/alerts` | CodeQL findings, **including dismissed ones** — check before filing, a finding may already have a decision |

Notes:

- Z3 proves **input grammars**. Last-admin arithmetic and the lock/tx state machine are covered by **host tests** on the real shell, not yet by a formal model.
- CodeQL runs via GitHub **default setup** (`actions`, `javascript-typescript`, `python`, extended suite), so there is no workflow file for it in this repo. Its `actions` queries cover unpinned action tags but treat `workflow_dispatch` inputs as trusted.
- Host prerequisites and the macOS gaps live in [developer/testing.md](developer/testing.md#host-smoke) — do not restate them here.

## Controls in force

Living reference, not a snapshot of one review. A new mutator, rpcd method, file-write path, or release step is not done until it has a named guard in one of these tables and a **proof of the matching class**.

**Proof class** (required column):

| Class | Meaning | Satisfied by |
|-------|---------|--------------|
| `host` | Property can be demonstrated without a live OpenWrt guest | Host tests under `tests/`, Z3, or shellcheck gates in `smoke-host.sh` |
| `lab` | Property depends on real ubus / rpcd / LuCI / package install | `qemu-smoke-*.sh` (or documented lab run) on a supported guest |
| `manual` | One-time or operator-facing check | Dated review note or published fingerprint table |

**False-green rule:** if a host test skips the security path (`USRMANAGE_DRY_RUN=1`, missing `ubus`/`jsonfilter`, argv stub), it must **not** be listed as Proof for a `lab`-class control. List it as “host harness only” and keep the lab proof (or an open release-blocking issue).

### Exploit

| Attack surface | Guard | Class | Proof |
|----------------|-------|-------|-------|
| Shell / command injection via username | Strict charset (`a-z0-9_-`, 1–32, deny-list) gates mutators and `show` | host | `tests/test_validators.sh` · Z3 P1 |
| Passwd/shadow line confusion via suffix username | Field-anchored awk `$1 == user` in `um_passwd_line` / `um_user_locked` ([#118](https://github.com/lucas-albers-lz4/usrmanage/issues/118) L10) | host | `tests/test_mutators.sh` (ntp/tp, daemon/n) |
| Password in argv / `ps` / logs | `--password-fd` or stdin; rpcd pipes fd 0; never audit/syslog | host | `tests/test_mutators.sh` stub argv |
| Audit field injection (actor/src) | Whitelist + 64-char cap (`um_actor_resolve`, `sanitize_actor`); audit tokens may contain `=` but never a space, so no new field can be introduced | host | #3 C1 · Z3 P2 |
| Unquoted argv rpcd → CLI | Explicit argv per ubus method | host | #3 C2 · `tests/test_mutators.sh` |
| View → manage escalation | Split rpcd ACL (`luci-app-usrmanage-session` / `-health` / app); server authoritative | host | `acl.d/luci-app-usrmanage.json` · `tests/test_health.sh` |
| Non-root mutators | `um_require_root` before manage commands | host | `tests/test_validators.sh` |
| XSS via username / audit text in LuCI | DOM via LuCI `E()`; no `innerHTML` | manual | Manual review of `usrmanage.js` |

### Integrity / login safety

| Failure scenario | Guard | Class | Proof |
|------------------|-------|-------|-------|
| Concurrent mutators on account files | Whole-mutator exclusive `flock` (`um_with_lock`); lock file created/tightened to `0600` via `um_lock_open` so unprivileged UIDs cannot take `LOCK_EX` (mutator path + doctor path, [#118](https://github.com/lucas-albers-lz4/usrmanage/issues/118) L11) | host | `tests/test_mutators.sh` (mode 0600 + upgrade-path tighten + doctor-first) |
| Crash mid-mutation | Snapshot / EXIT rollback (`um_tx_*`) over passwd+shadow+group+registry+rpcd (create/delete/set-role / set-luci-login). Del commits BEFORE `um_registry_del` (purge may remove the home). Rollback restores via temp+rename (I4). Post-commit registry failure keeps `incomplete` (I5). | host | `tests/test_phase1_foundation.sh` · `tests/test_luci_login.sh` |
| Torn file writes | `umask 077` temp → fixed mode/`chown 0:0` → `mv` (`um_atomic_edit`, registry del, audit rotate, `um_tx_restore_one`); `um_rpcd_atomic_replace` preserves destination mode (default `0600`); `incomplete` marker `0640` ([#125](https://github.com/lucas-albers-lz4/usrmanage/issues/125) L12) | host | `tests/test_phase1_foundation.sh` · `tests/test_luci_login.sh` (rpcd/audit mode asserts) · `tests/test_mutators.sh` (L12) |
| SIGKILL / power loss mid-mutation | **Accepted residual**: EXIT-trap rollback cannot run; `doctor` reports orphaned `usrmanage-tx.*` snapdirs for manual recovery. Snapdirs live in `${TMPDIR:-/tmp}` (tmpfs) — recovery applies only if the snapshot survives until the operator acts (#96, #100) | host | `um_doctor_checks` |
| Demote/delete last managed admin | `um_count_managed_admins` deny | host | `tests/test_mutators.sh` · QEMU smoke |
| Incomplete op with no record | `incomplete` marker (`0640`/`0:0`, not ambient umask) + `doctor`; failed restore keeps snapdir | host | `um_doctor_checks` · `tests/test_mutators.sh` (L12) |
| Broken sudoers fragment | Minimal static `%wheel` rule; Makefile + uci-defaults `chmod 0440`; `doctor` asserts mode 0440 via validated `stat` output or BusyBox-safe `find -maxdepth 0 -perm 440` (symlink rejected before `[ -f ]`), then `visudo -cf`. Wheel missing with no live managed users is **warn** only (created on first add). Doctor does not chmod or create wheel (read ACL). | host | `um_doctor_checks` · `scripts/smoke-package-layout.sh` · `tests/test_mutators.sh` (V3 0644) · `tests/test_doctor.sh` (stat stub / garbage / symlink / wheel severity) |
| Upgrade/remove wiping managed state | `users`, sudoers, UCI config are conffiles | host | package Makefile |

### LuCI login lifecycle

| Failure scenario | Guard | Class | Proof |
|------------------|-------|-------|-------|
| Empty / locked shadow accepted for web login | Refuse enable when hash empty or `!`/`*` | host | `tests/test_luci_login.sh` |
| Adopt foreign / tampered `luci-app-acl` login | Ownership conjunction (`usrmanage=1` + `$p$user` + managed registry) with fail-closed parser for non-canonical UCI | host | `tests/test_luci_login.sh` |
| Login section written in a libuci-valid form the awk parser cannot see | Fail-closed `um_rpcd_config_parsable` refuses indented, abbreviated, quoted-type sections, quoted option/list keys, and trailing `#` on option/list lines ([#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) / [#118](https://github.com/lucas-albers-lz4/usrmanage/issues/118) L8/L9) | host | `tests/test_luci_login.sh` (indented / abbreviated / quoted / quoted_keys / trailing_comment) |
| `/etc/config/rpcd` mode preserved on rewrite / rollback | Capture dest mode in `um_rpcd_atomic_replace` (default `0600`); `um_tx_restore_one` has a dedicated `rpcd` arm at `0600` | host | `tests/test_luci_login.sh` (enable/disable/reset + forced rollback) |
| Live session keeps old ACLs after disable / role / del / passwd | `um_session_revoke_user` destroys matching ubus SIDs (`@.values.username` then `@.data.username`). SID list is **field-anchored** on `"ubus_rpc_session"` (greedy 32-hex extract matched ACL payload noise → `session_revoke_unavailable`). Concurrent `session.login` during revoke remains an **accepted residual** (I3) | lab | `scripts/qemu-smoke-usrmanage.sh` (issue #95) · `tests/test_luci_login.sh` (SID extract) — host DRY_RUN skips ubus and is **not** proof |
| Same-role / ACL-repair `set-role` leaves elevated live sessions | After `um_luci_login_sync_acls` in set-role (including same-role), `_um_set_role_revoke` runs fail-closed | host | `tests/test_luci_login.sh` (behavioral same-role mock) |
| `set-luci-login` multi-index rewrite crash window | Resolved — `um_mut_set_luci_login` uses `um_tx_*` for enable/disable/reset ([#106](https://github.com/lucas-albers-lz4/usrmanage/issues/106) / [PR #114](https://github.com/lucas-albers-lz4/usrmanage/pull/114)) | host | `tests/test_luci_login.sh` (L2 tx asserts) |
| New `session.login` denied after disable; demote drops write on re-login | lab for **canonical** owned login sections (P1/P2) | lab | `scripts/qemu-smoke-usrmanage.sh` (#107 / [PR #116](https://github.com/lucas-albers-lz4/usrmanage/pull/116)) |
| Readonly diagnostic LuCI obtains forbidden ACL / write paths | Session ACL has no uci. Health is `usrmanage.health` only. Diagnostic grants selected stock status/network ACL **names on `list read` only** plus narrow `luci-app-usrmanage-diagnostic-rpc` (dump / uci get+changes / board+host+netdev hints — **not** getWirelessDevices, no luci-base, no write). Exact set match; `*` / `luci-base` → tampered. View-only UM (app ACL read, no write). **Accepted residual (#156):** web-path `uci get`/`changes` over network-config packages (`network`/`wireless`/`dhcp`/`firewall`/`system`) plus `luci-rpc.getHostHints` (lease/neighbor MAC↔IP/hostname hints needed by stock Interfaces). Still no Overview SSID DOM path / getWirelessDevices / luci-base file list. | host + lab | `tests/test_health.sh` · `tests/test_luci_login.sh` · `tests/test_diagnostic_page_rpc_contract.py` · `scripts/qemu-smoke-usrmanage.sh` · Playwright `#156` · lab 2026-08-22 ACL probes on 0.1.13 |
| Health RPC grows secret fields / pass-through blobs | Frozen schema projector (`um_health_json_emit`); `health` takes no params; hostile body ignored (no `read_input`); DRY_RUN fixture equality | host | `tests/test_health.sh` (schema equality, not deny-list grep as sole proof) |
| Admin owned LuCI / upgrade widen | Admin+LuCI is always `usrmanage_scope=full` (`*`). `--scope` rejected (`luci_scope_role_locked`). Upgrade migrate rewrites legacy `app` → full and readonly → diagnostic; refuse `*` when rpcd unparsable | host | `tests/test_luci_login.sh` · `91-usrmanage-readonly-observer` |
| Demote admin (`*`) leaves live SID with old ACLs | Rewrite ACL first (drop `*` → diagnostic), revoke, drop wheel, revoke again; fail closed if SID remains when ubus present | lab | `scripts/qemu-smoke-usrmanage.sh` (demote leftover SID dead). Host order mock in `tests/test_luci_login.sh` is **not** lab proof |
| rpcd pending UCI changes during enable/disable | Refuse when `uci changes rpcd` non-empty | host | `tests/test_luci_login.sh` |

### Supply chain

| Failure scenario | Guard | Class | Proof |
|------------------|-------|-------|-------|
| Unsigned or third-party-signed feed | opkg `usign` + apk RSA signing in the publish job; keys validated before use | host | `scripts/validate-feed-keys.sh` (not invoked by `smoke-host.sh` — needs docker + secrets) |
| Signing secret leaking into the published feed | Staging copies public key material only | host | `feed_publish_copy_keys` |
| Silently altered build inputs | Feed commits pinned in `scripts/feeds.lock/`; SDK image pinned to registry digest at first **secret-touching** pull (`sdk_matrix_pull_and_pin` in `validate-feed-keys.sh` before the usign container; later staging prefers the pin cache) | host | `tests/test_sdk_matrix_digests.sh` (R4 pin cache + R7 grep) · `sdk_matrix_feeds_ready` |
| Signing secret exfil via SDK container network | `--network none` on every container that bind-mounts a signing secret (`validate-feed-keys.sh` usign check; `feed_publish_stage_opkg_sdk` / `feed_publish_stage_apk` sign steps) ([#125](https://github.com/lucas-albers-lz4/usrmanage/issues/125) R7) | host | `tests/test_sdk_matrix_digests.sh` (R7 grep) |
| Non-reproducible release artifacts | `SOURCE_DATE_EPOCH` from the tag commit + repro gate | host | `scripts/verify-reproducible-build.sh` |
| Publish job token / build container isolation | Checkout `persist-credentials: false`; signing tools copied out of `/builder` before secret mounts | manual | `publish-packages.yml` · `feed_publish_stage_opkg_sdk` / `feed_publish_stage_apk` |
| Signing keys never visible to the tool-export container | Export runs in the dedicated `sdk-export` compose service (SDK volume only, **no workspace mount**) as the invoking uid; workspace holds the keys (`.:/work/usrmanage:ro` is only on the `sdk` build service) | manual | `docker-compose.yml` `sdk-export` · `feed_publish_stage_opkg_sdk` / `feed_publish_stage_apk` export steps |
| Pages deploy-key action pin | `peaceiris/actions-gh-pages` SHA-pinned (`84c30a85c…` = `v4.1.0` as of 2026-08-13); CodeQL alert 2 closed as **fixed**; pin re-checked before each `v*` tag ([#126](https://github.com/lucas-albers-lz4/usrmanage/issues/126)) | manual | `publish-packages.yml` · [github-publish-checklist.md](github-publish-checklist.md) |
| Feed origin trust-bootstrap README | Fingerprints + `sha256sum -c` gate in in-tree `packages-repo/README.md` (copied to Pages on every publish) | manual | `packages-repo/README.md` · [binary-feed.md](binary-feed.md) |
| Published feed unusable / install breaks silently | Post-publish QEMU feed smoke (`smoke-from-feed` job): boots a fresh OpenWrt guest, installs from the live Pages URL, runs `usrmanage doctor` + core flows — always on tag pushes (dispatch can set `feed_smoke=false`) | lab | `publish-packages.yml` · `scripts/validate-feed-smoke.sh` · `scripts/wait-feed-pages.sh` · `scripts/download-openwrt-x86-64.sh` |

## Open findings

One open security finding ([#159](https://github.com/lucas-albers-lz4/usrmanage/issues/159), tracked below). #148–#150 closed 2026-08-21; #158 in [PR #160](https://github.com/lucas-albers-lz4/usrmanage/pull/160). I3 remains an accepted residual.

| Issue | IDs | Severity | Area | Notes |
|-------|-----|----------|------|-------|
| [#159](https://github.com/lucas-albers-lz4/usrmanage/issues/159) | — | Low | publish / supply chain | Feed signing keys written before SDK build cells mount workspace — defer key write until after builds |

## Resolved findings

Resolved by the audit remediation wave. Close the tracking issue when the fix lands.

| Issue | Area | Resolved by |
|-------|------|-------------|
| [#158](https://github.com/lucas-albers-lz4/usrmanage/issues/158) | rpcd ACL | [PR #160](https://github.com/lucas-albers-lz4/usrmanage/pull/160) — `show` requires write ACL; readonly fails closed with `access_denied` (no CLI / no existence oracle) |
| [#150](https://github.com/lucas-albers-lz4/usrmanage/issues/150) | LuCI login | merged 2026-08-21 — tampered owned login auto-revoke + doctor `luci_tampered` error |
| [#148](https://github.com/lucas-albers-lz4/usrmanage/issues/148) | password | merged 2026-08-21 — SHA-512 verify-then-fallback on `um_password_write` |
| [#149](https://github.com/lucas-albers-lz4/usrmanage/issues/149) | rpcd ACL | merged 2026-08-21 — `list --all` write-ACL gate (`session_has_write_acl`) |
| [#125](https://github.com/lucas-albers-lz4/usrmanage/issues/125) L12/R7 | On-device / publish | [PR #128](https://github.com/lucas-albers-lz4/usrmanage/pull/128) — incomplete marker `0640`; `sdk_matrix_pull_and_pin` before usign secret mount; `--network none` on secret containers |
| [#126](https://github.com/lucas-albers-lz4/usrmanage/issues/126) | CI record / pin hygiene | Alert 2 reopened then **fixed** (2026-08-13); pre-release SHA re-check in [github-publish-checklist.md](github-publish-checklist.md) ([PR #128](https://github.com/lucas-albers-lz4/usrmanage/pull/128)) |
| [#118](https://github.com/lucas-albers-lz4/usrmanage/issues/118) L8–L11, I4/I5, V2/V3 | On-device | [PR #121](https://github.com/lucas-albers-lz4/usrmanage/pull/121) (L8–L11) + [PR #122](https://github.com/lucas-albers-lz4/usrmanage/pull/122) (I4/I5/V2/V3); I3 → accepted residual |
| [#117](https://github.com/lucas-albers-lz4/usrmanage/issues/117) R1–R6, P1 | Publish / supply-chain | [PR #120](https://github.com/lucas-albers-lz4/usrmanage/pull/120) — persist-credentials false; packages-repo README fingerprints; signing tools exported; SDK digest pin; tag validation; feed-publish environment; blocking shellcheck |
| [#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105) L1/L3 | LuCI login / shadow | [PR #115](https://github.com/lucas-albers-lz4/usrmanage/pull/115) — same-role set-role revoke + `um_shadow_hash_usable` awk `$1 == u` field match |
| [#106](https://github.com/lucas-albers-lz4/usrmanage/issues/106) L2 | LuCI login tx | [PR #114](https://github.com/lucas-albers-lz4/usrmanage/pull/114) — `set-luci-login` transaction snapshot |
| [#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) L4 | LuCI login parser | [PR #113](https://github.com/lucas-albers-lz4/usrmanage/pull/113) — fail-closed for indented / abbreviated / quoted-type sections (further grammar: #118 L8/L9) |
| [#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) L5/L6 | On-device file modes | [PR #112](https://github.com/lucas-albers-lz4/usrmanage/pull/112) — preserve rpcd mode; audit rotate umask |
| [#111](https://github.com/lucas-albers-lz4/usrmanage/issues/111) L7 | Op lock mode | [PR #112](https://github.com/lucas-albers-lz4/usrmanage/pull/112) — `um_lock_open` 0600 on mutator path (doctor path closed in #118 L11) |
| [#107](https://github.com/lucas-albers-lz4/usrmanage/issues/107) P1/P2 | Lab / LuCI login | [PR #116](https://github.com/lucas-albers-lz4/usrmanage/pull/116) — qemu-smoke post-disable deny + demote write ACL |
| [#61](https://github.com/lucas-albers-lz4/usrmanage/issues/61) S1/S3/S4 | CLI / rpcd | [PR #80](https://github.com/lucas-albers-lz4/usrmanage/pull/80) — `grep -F` username lookups, rpcd session hex whitelist, role resolution before audit (passwd/shadow field-anchored in #118 L10) |
| [#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63) R1–R5 | CI / release | [PR #78](https://github.com/lucas-albers-lz4/usrmanage/pull/78) + [PR #79](https://github.com/lucas-albers-lz4/usrmanage/pull/79) + [PR #82](https://github.com/lucas-albers-lz4/usrmanage/pull/82) — env-routing, usign key 0600, SHA-pins + actionlint gate, tooling pins (SDK digest pin completed in #117) |
| [#64](https://github.com/lucas-albers-lz4/usrmanage/issues/64) | Operator trust | [PR #81](https://github.com/lucas-albers-lz4/usrmanage/pull/81) — key fingerprints published; in-tree `packages-repo/README.md` gate restored in #117 |
| [#65](https://github.com/lucas-albers-lz4/usrmanage/issues/65) P1/P2 | Product | [PR #83](https://github.com/lucas-albers-lz4/usrmanage/pull/83) — test-only env-override gate and multi-line / control-char password rejection |
| [#66](https://github.com/lucas-albers-lz4/usrmanage/issues/66) | Tooling | [PR #84](https://github.com/lucas-albers-lz4/usrmanage/pull/84) — portable stat helper, flock shim, and skip reasons. The full gate runs on macOS. |
| [#95](https://github.com/lucas-albers-lz4/usrmanage/issues/95) | Lab / LuCI login | [PR #103](https://github.com/lucas-albers-lz4/usrmanage/pull/103) — qemu-smoke asserts live session revoke; `@.values.username` verified on 24.10.8 |

## Accepted residuals

Do not re-open without new evidence.

| Accepted risk | Rationale |
|---------------|-----------|
| Password traverses ubus JSON once (LuCI → rpcd) | Platform pattern (same as stock LuCI `setPassword`); TLS ops guidance; never argv/logs after |
| Local `audit.log` not tamper-evident | Root can rewrite any local file; operational claim only |
| `userdel -r` may follow symlinked home on purge | Matches stock tools; avoid `--purge-home` on untrusted homes |
| No `flock -w` timeout | BusyBox constraint; see #61 S2 for optional diagnostics. Reachability by unprivileged UIDs was closed by [#111](https://github.com/lucas-albers-lz4/usrmanage/issues/111) (`um_lock_open` → `0600`); a stuck *root* holder can still block callers indefinitely |
| UI `hasWriteAcl` best-effort | Server ACL is authoritative |
| Best-effort process kill on delete | Account lock still blocks new logins |
| Admin role means full root via sudo | Product lock, by design — see [AGENTS.md](../AGENTS.md) |
| Session revoke vs concurrent `session.login` TOCTOU (I3) | Enumerate-then-destroy; a login that races between list and destroy can keep its SID. Sequential revoke is lab-proven (#95). Hardening would need platform session hooks; accepted 2026-08-12 |
| Lab fixtures ship hardcoded passwords | `scripts/qemu-*.sh` and `tests/e2e/` never ship in a package |

Plus the won't-fix bucket from issue #3, listed in its history entry below.

## Audit history

### 2026-08-05 — Pre-0.1.0 architecture review

Scope: `openwrt-feed/usrmanage`, `openwrt-feed/luci-app-usrmanage`, docs, host tests.

| Item | Status |
|------|--------|
| Single CLI code path for LuCI + shell | Pass — rpcd wraps `/usr/sbin/usrmanage` |
| Split read/write rpcd ACL | Pass — `list/show/audit/doctor/policy` vs write methods |
| Managed-user registry | Pass — `/etc/usrmanage/users` |
| Last managed admin guard | Pass — demote/delete |
| Revoke → lock → kill → delete sequence | Pass — `um_mut_del` (session revoke + rpcd login removal precede lock/delete; both inside the tx snapshot) |
| Exclusive op lock | Pass — `flock` (no mkdir fallback) |
| Password not in argv | Pass — `--password-fd` / stdin |
| Actor attribution | Pass — CLI id; LuCI session best-effort / `unknown` |
| Operational audit claim documented | Pass — `docs/security.md` |
| Ash-safe / ShellCheck | Pass — `./scripts/shellcheck.sh` |
| Arch-independent packaging | Pass — `PKGARCH` / `LUCI_PKGARCH:=all` |

Residual items from this pass (still accepted unless noted later): ubus password hop, UI write-ACL hint vs server ACL, best-effort process kill, non-tamper-evident local audit.

### Issue #3 — Critical and major findings (fixed)

Tracking: [issue #3](https://github.com/lucas-albers-lz4/usrmanage/issues/3). Critical findings C1–C7 landed in [PR #4](https://github.com/lucas-albers-lz4/usrmanage/pull/4); major findings in [PR #5](https://github.com/lucas-albers-lz4/usrmanage/pull/5); the LuCI error-detail finding (M8) in [PR #7](https://github.com/lucas-albers-lz4/usrmanage/pull/7); host mutator/lock/rpcd tests (M9) and the remaining lower-priority items in follow-up PRs (#10/#11 and later hardening).

| ID | Finding | Status |
|----|---------|--------|
| C1 | actor/src whitelist (audit field injection) | Fixed |
| C2 | rpcd explicit quoted CLI argv (no unquoted `$*`) | Fixed |
| C3/C4 | flock-only lock (mkdir fallback removed) | Fixed |
| C5 | jsonfilter required (sed password fallback removed) | Fixed |
| C6 | dead `json_escape` removed | Fixed |
| C7 | audit `denied` on mutator validation failures | Fixed |
| M1 | Orphan account if wheel-add fails after `useradd` | Fixed |
| M2/M5 | Wheel demote/delete verify; demote hard-fail | Fixed |
| M3 | `um_registry_add` unchecked | Fixed |
| M7 | `--password-fd` must be numeric | Fixed |
| M4 | Strict dirs before lock | Fixed |
| M6 | Wheel creation consolidated | Fixed |
| M8 | LuCI surfaces CLI `error:` tokens | Fixed |
| M9 | Host tests for lock / mutators / rpcd argv | Fixed |

Won't-fix / accepted bucket from #3 (do not re-open without new evidence): client/server password-policy duplication; `um_actor_resolve` preferring `$USER` (mitigated by C1); `/proc` kill fallback; audit `tail -c` mid-line rotation; ash `set -e` without `pipefail`; `userdel -r` symlink follow on purge (document: avoid `--purge-home` on untrusted homes).

### 2026-08-09 — Exploit + integrity review (usrmanage focus)

Scope: CLI (`usrmanage`), `usrmanage-lib.sh`, rpcd plugin, ACL, sudoers, uci-defaults, LuCI view, host tests, `scripts/z3-verify.py`. Compared to [threat-model.md](threat-model.md) and issue #3.

**Method:** read security-relevant code; walk injection / escalation / race / lockout paths; re-run host smoke / Z3 where available.

**Result:** no new confirmed auth bypass, privilege escalation, or passwd/shadow/group corruption on paths that already pass validation. Established the exploit and integrity rows now kept under [Controls in force](#controls-in-force). Candidate follow-ups: [#61](https://github.com/lucas-albers-lz4/usrmanage/issues/61) (S1–S4). Related fwlive candidate (same pass, not a full fwlive audit): [fwlive#129](https://github.com/lucas-albers-lz4/fwlive/issues/129).

### 2026-08-09 — Supply-chain / CI review

Scope: the surfaces the two prior passes never opened — `.github/workflows/`, `.github/dependabot.yml`, `scripts/publish-packages.sh`, `scripts/lib/feed-keys.sh`, `scripts/lib/feed-publish.sh`, `scripts/validate-feed-keys.sh`, `scripts/lib/sdk-matrix.sh`, `scripts/feeds.lock/`, `docs/binary-feed.md`, plus a re-read of the CLI, rpcd, and LuCI view against the control tables.

**Method:** trace what an operator installs as root back to its inputs — who can influence the publish job, how signing keys are handled, what tooling is fetched at release time, and how a router decides to trust the feed. Gates re-run: `smoke-host.sh` (8 of 10 stages on macOS, see [#66](https://github.com/lucas-albers-lz4/usrmanage/issues/66)) and `z3-verify.py --full` (green).

**Result:** no remotely triggerable vulnerability. Five release-pipeline items ([#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63)), one operator trust-bootstrap gap ([#64](https://github.com/lucas-albers-lz4/usrmanage/issues/64)), two product defense-in-depth items ([#65](https://github.com/lucas-albers-lz4/usrmanage/issues/65)). The one finding reproduced end to end is #63 R2: a usign secret key ends up mode 0644 whenever it is stored base64 or needs newline normalization, because the temp file written during decode inherits the ambient umask and then replaces the key.

Confirmed still holding, no change needed: audit field injection (#3 C1) — audit tokens accept `=` but never a space, so a hostile username cannot introduce a new space-delimited field; LuCI renders every user-controlled string through `E()`; and no secret key material reaches the published feed staging directory.

### 2026-08-12 — Process failure review (post LuCI login / #95)

Scope: how design locks and “security done” claims were allowed to merge without matching proofs — especially after the LuCI login lifecycle (PRs #87/#89) and zen-MCR findings #92–#98.

**Failures observed:**

1. **Repeated find→fix waves** (#3, shadow-free #42/#49, Aug-9 #61–#65, LuCI login #92–#98) instead of requiring pre-merge proof for new security surfaces.
2. **Unchecked lab boxes on feature PRs** that already claimed security locks (PR #87 listed session revoke; “Demote/disable revokes live ubus session” stayed unchecked at merge).
3. **DRY_RUN / stub false-green** — `USRMANAGE_DRY_RUN=1` makes `um_session_revoke_user` return 0 without ubus; host tests counted as coverage while the live path was unproven (#95).
4. **Lab verification scoped out of P0** (#90) without a release-blocking follow-up — became #95 only after another MCR pass.
5. **Coverage map lag** — new LuCI login surface dates were not bumped on the feature PR; lab-class controls were not called out until after merge.

**Process changes** (this revision of the ledger): proof-class column (`host` | `lab` | `manual`); false-green rule; feature PR gate and pre-merge review trigger in [Review procedure](#review-procedure); LuCI login lifecycle rows under [Controls in force](#controls-in-force); session revoke marked `lab` with qemu-smoke proof from #95 / PR #103.

### 2026-08-12 — Exhaustive pass: LuCI login ownership + on-device file discipline

Scope: LuCI login lifecycle, session revoke, ACL ownership, set-role interaction with owned logins, CLI arg parser, rpcd plugin, ACL JSON, LuCI view, package Makefile / uci-defaults / sudoers, CI workflows. Brief: [security-opus-luci-login-brief.md](security-opus-luci-login-brief.md). Full write-up with reproductions: [security-audit-luci-login-2026-08-12.md](security-audit-luci-login-2026-08-12.md).

**Method:** line-level review cross-checked against upstream OpenWrt sources rather than against our own docs — `rpcd/session.c` (login/ACL resolution, crypt-hash passwords), `libuci/file.c` (real config grammar), `rules.mk` + `package/system/rpcd/Makefile` (installed file mode). Every finding reproduced in a throwaway host harness before filing.

**Result:** no remote unauthenticated exploit; ordering invariants from #92–#101 all hold as written. Two new findings, both **classes rather than one-offs**:

- [#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) **L4** — the ownership model rests on an awk parser narrower than libuci (indented, `c`-abbreviated, and quoted-type sections are invisible). `disable` returns `ok` and audits `luci_revoke … result=ok` while the login still authenticates; `del` can leave a crypt-hash web credential behind after the UNIX account is gone; the `login_exists_foreign` guard is bypassed on `enable`.
- [#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) **L5/L6** — `um_rpcd_atomic_replace` hardcodes `chmod 0644`, downgrading `/etc/config/rpcd` from the `0600` OpenWrt ships via `INSTALL_CONF`, on the first `set-luci-login`. Same temp-file/mode class as #63 R2, which was fixed in the release pipeline and never swept on-device. `um_audit_rotate_if_needed` has the same shape.

**Follow-on, same day, from the sibling repo.** Auditing `fwlive` with these three classes in hand (temp-file mode loss, unswept fix classes, hand-parsed platform formats) surfaced a fourth instance of the file-mode class that points back here: [#111](https://github.com/lucas-albers-lz4/usrmanage/issues/111) **L7** — `um_with_lock` creates `/var/lock/usrmanage.lock` via `9>` under the ambient umask (0644), and `flock(2)` grants `LOCK_EX` on a read-only descriptor. A managed unprivileged user can therefore hold the op lock and block every mutator, including the `del`/`set-role` that would revoke them, until reboot. This is new evidence against the accepted `flock -w` residual, which had assumed the holder is trusted. The same construct and fix apply in [fwlive#167](https://github.com/lucas-albers-lz4/fwlive/issues/167).

The file-mode class has now produced four instances (#63 R2, #109 L5, #109 L6, #111 L7) and no test in this repo has ever asserted the mode of a file the package writes. That argues for running rule 1 of the prevention plan as a single sweep across every file `usrmanage` creates, rather than reactively per report.

L1 severity revised Medium → Low (drift requires a prior root write). Non-findings re-confirmed: CLI arg parser cannot be turned into option injection from ubus, rpcd argv/password path, audit token grammar, no XSS sink in the view, ACL split, env-override gate, symlink refusal on home create/remove, sudoers `0440` static `%wheel`, SHA-pinned CI. Prevention plan: [security-prevention-plan.md](security-prevention-plan.md).

### 2026-08-12 — Multi-model pass (Opus / Grok / Sol / GLM)

Scope: cooperative + adversarial audit after L1–L7 remediations on `main` @ `526ea73`. Angles: supply-chain/CI (Opus, deliberately not re-litigating LuCI login), adversarial exploit (Grok), integrity/races (Sol), control+ledger verification (GLM). Parent re-checked the highest-severity claims on host.

**Gates:** `./scripts/smoke-host.sh` PASS · `python3 scripts/z3-verify.py --full` PASS. QEMU lab not re-run this pass.

**Result:** no remote unauthenticated RCE. New tracking issues:

- [#117](https://github.com/lucas-albers-lz4/usrmanage/issues/117) — publish TCB (R1 High: checkout credentials in SDK mount; R3 feed README trust regression **blocks next tag**; R2/R4/P1/R5/R6).
- [#118](https://github.com/lucas-albers-lz4/usrmanage/issues/118) — on-device leftovers (L8/L9 incomplete L4 grammar; L10 unanchored passwd/shadow grep; L11 doctor lock DoS; I3–I5; V2/V3 proof gaps).

Ledger hygiene in this revision: coverage-map dates bumped; L1–L7 moved to Resolved; L2 control row marked fixed; open findings table wired to #117/#118; duplicate closing notes removed.

### 2026-08-12 — Publish TCB remediation (#117)

Scope: `.github/workflows/publish-packages.yml`, `packages-repo/README.md`, `scripts/lib/{sdk-matrix,feed-publish}.sh`, `scripts/{docker-sdk,shellcheck,publish-packages,verify-reproducible-build}.sh`, `docs/{release,security-review}.md`, `tests/test_sdk_matrix_digests.sh`.

**Result:** R1–R6 and P1 closed. Checkout no longer persists credentials into the SDK bind mount; feed README fingerprint gates restored in-tree; signing tools exported off `/builder` before secret mounts; SDK digests pinned at first pull with cache for manifest; tag shape validated without `${{ }}` in `run:`; `environment: feed-publish` added (operator must configure reviewers); bash shellcheck is blocking. Host smoke + digest tests green. Residual operational notes: configure Environment in GitHub settings; optional checkout-before-validate ordering.

### 2026-08-12 — On-device L8–L11 remediation (#118 partial)

Scope: `usrmanage-lib.sh` (passwd/shadow field match, doctor `um_lock_open`), `usrmanage-luci-login.sh` (`um_rpcd_config_parsable` quoted keys + trailing comments), host tests.

**Result:** L8/L9 fail-closed; L10 field-anchored lookups; L11 doctor-first lock 0600. Remaining #118 items (I3–I5, V2/V3) tracked for the follow-up PR.

### 2026-08-12 — On-device I4/I5/V2/V3 + I3 residual (#118 complete)

Scope: `um_tx_restore_one` atomic restore, del incomplete retention, same-role revoke behavioral test, sudoers mode asserts, accepted residual for session-login TOCTOU.

**Result:** #118 closed. I3 documented under Accepted residuals.

### 2026-08-13 — Doctor severity + BusyBox sudoers mode probe

Scope: `um_doctor_checks` / `um_file_mode_octal` / `um_count_managed_users`, LuCI doctor banner, `tests/test_doctor.sh`.

**Result:** Top-level `ok` ignores warn-severity checks (empty-registry missing wheel). Sudoers mode via validated `stat` or `find -perm 440`; symlinks fail closed. LuCI: no green banner; warn collapsed / error expanded; raw JSON under details. Doctor remains read-only (no chmod / no create wheel).

### 2026-08-13 — Re-verification pass (filed #125 / #126)

Scope: oldest coverage-map surfaces from 2026-08-12. Class sweep (temp-file mode, hand-parsed formats, fetch pinning). Gates: `smoke-host.sh` PASS, `z3-verify.py --full` PASS. QEMU not re-run.

**Result:** two Low findings filed as [#125](https://github.com/lucas-albers-lz4/usrmanage/issues/125) (L12 incomplete marker 0644; R7 unpinned SDK at first secret mount). [#126](https://github.com/lucas-albers-lz4/usrmanage/issues/126) recorded a stale CodeQL alert-2 won't-fix; the alert was reopened and resolved as **fixed** the same day (`peaceiris/actions-gh-pages@84c30a85c…`).

### 2026-08-15 — #125 / #126 closeout

Scope: `um_incomplete_set`, `scripts/validate-feed-keys.sh`, `scripts/lib/feed-publish.sh` secret compose runs, publish checklist, this ledger.

**Result:** L12 marker write uses umask 077 + `chmod 0640` / `chown 0:0` with a host `stat` assert. R7 validate path calls `sdk_matrix_pull_and_pin` before mounting the usign secret; secret-touching containers use `--network none`. #126 remaining work is the pre-release pin re-check (Dependabot version PRs stay off; no Pages-deploy TCB shrink). Open findings table empty.

### 2026-08-18 — R7 publish regression fix (v0.1.5 first publish)

Scope: `scripts/lib/feed-publish.sh` opkg/apk sign steps; first publish after the 2026-08-15 R7 closeout failed.

**Root cause (two bugs).** (1) The R7 change added `--network none` to `docker compose run`, but **Compose v2's `run` subcommand has no `--network` flag** — the sign step died with `unknown flag: --network` before doing anything. (2) Independent of that, OpenWrt SDK `staging_dir/host/bin/{usign,mkhash,apk}` are **runas wrapper scripts**, not plain binaries: `bin/<tool>` execs `../lib/ld-linux-x86-64.so.2` with `LD_PRELOAD=../lib/runas.so` against the hidden real binary `bin/.<tool>.bin`. Exporting only the bare wrapper (R2/R7 design) leaves `../lib` and `.bin` siblings unresolvable — verified across 21.02.7 / 24.10.8 / 25.12.5 SDK tarballs.

**Fix.** (1) Sign step switched from `docker compose run --network none` to `docker run --rm --network none --platform linux/amd64` with the digest-pinned `$SDK_MATRIX_IMAGE` (fwlive's R7 pattern; no `/builder` mount, keys `:ro`). (2) Export copies the wrapper **and** the hidden `.bin` into `tools_dir` and the shared-lib tree (`*.so*` only) into a separate `lib_dir`, mounted as siblings at `/feed/tools` + `/feed/lib`; export runs in the dedicated `sdk-export` compose service (SDK volume only, **no workspace mount**) as the invoking uid — the workspace holds the signing keys, so the export container must never see them. `validate-feed-keys.sh` was already correct (runs usign in-image with `--network none`).

**Result.** `bash -n` clean; fix verified by re-running the publish workflow (v0.1.5). Controls in force unchanged — the R7 security properties (digest pin before secret mount, `--network none`, no `/builder` in secret containers, keys never visible to the export container) are preserved.

### 2026-08-19 — Readonly observer LuCI (HARD path, spec revision 2)

Scope: owned LuCI ACL matrix, `usrmanage.health` RPC, demote order, luci-app upgrade migration. Design SoT: [developer/readonly-observer-luci.md](developer/readonly-observer-luci.md).

**Locks implemented.** Readonly owned reads = session + health only (no app list/enum). Session ACL has no `uci`. Health method is declared read, takes no params, ignores the request body, and emits a frozen schema (no WAN IP / SSID / MAC / lease lists). Admin default stays app scope; `*` only via `--scope full` (refused on readonly and if rpcd is unparsable). Demote rewrites ACLs to health before revoke, revokes twice, and fails closed if a SID remains when ubus is present. luci-app uci-defaults migrate owned readonly logins with `um_luci_login_ours_index` + flock/tx; never unmarked/`root`; never auto-`*`.

**Proof.** Host: `tests/test_luci_login.sh`, `tests/test_health.sh`, `scripts/smoke-package-layout.sh`. Lab asserts added to `scripts/qemu-smoke-usrmanage.sh` (readonly deny/allow, admin app vs full wireless, demote leftover SID). DRY_RUN is not lab proof. SSH residual for the same UNIX password remains an accepted LuCI-only guarantee (spec §12 / §16).

### 2026-08-20 — Role-locked LuCI scopes (diagnostic / full)

Scope: owned LuCI ACL matrix, CLI/rpcd/UI (drop `--scope` picker), migrate, demote/promote. Design: [developer/readonly-observer-luci.md](developer/readonly-observer-luci.md), [user/roles-and-acl.md](user/roles-and-acl.md). PR [#143](https://github.com/lucas-albers-lz4/usrmanage/pull/143).

**Locks.** Admin+LuCI → always `usrmanage_scope=full` (`*`). Readonly+LuCI → `diagnostic` with curated stock status/network ACL **names on `list read` only** plus session/health/app view; empty write list. View-only User Management for readonly. `--scope` → `luci_scope_role_locked`. Upgrade migrate rewrites legacy admin `app` → full and readonly → diagnostic. Demote drops `*` → diagnostic before revoke.

**Opus 5 security pass (same day).** No medium+ vulnerabilities vs the intentional product model. Scope is server/role-derived (client `scope` ignored). Demote/migrate ordering + field-anchored SID revoke sound. Intentional exposures (not bugs): diagnostic `uci get wireless` (network-config read); admin LuCI always full (upgrade widen). Residuals unchanged: SSH same-password shell; I3 concurrent login race; UI `hasWriteAcl` best-effort vs server ACL.

**Proof class.** `host`: `tests/test_luci_login.sh`, `tests/test_mutators.sh`, `./scripts/smoke-host.sh`. `lab`: `scripts/qemu-smoke-usrmanage.sh` (diagnostic get allow / set+add deny; admin full wireless get; `--scope` rejected; demote SID) — **lab run pending**: the dated successful qemu-smoke run must be recorded here before merge. `manual`: Opus review of branch diff.

### 2026-08-21 — Zen security pass + rpcd list write-ACL gate (#149)

**Scope.** Read-only security review of the shipped surface (main @ 8959550) using the zen `x-preview-f-free` model at max reasoning; findings triaged against code. Filed #148 (chpasswd sha512 pin), #149 (`list --all` enumeration), #150 (tampered fail-open). This entry covers the #149 fix: the ubus `list` method honored `all` from any read-ACL session, enumerating every passwd row >= UID floor. The LuCI view only ever sends `all:false`, so `--all` was reachable only via direct ubus — including diagnostic-scope sessions.

**Fix.** `session_has_write_acl` in the rpcd plugin probes `ubus call session access` on `usrmanage.add` (RPC_SESSION hex-guarded before interpolation; ANY failure fails closed). `all` is honored only when the caller holds the write ACL; plain `list` unchanged; CLI `list --all` remains root-only.

**Proof.** host: `tests/test_rpcd_list_acl.sh` (shimmed ubus/jsonfilter/CLI — write-ACL honored / readonly stripped / no-ubus fail-closed / bad-SID fail-closed / `all:false` unchanged; red on gate revert), full `./scripts/smoke-host.sh` green. lab: none — no new lab surface, method scope unchanged.

### 2026-08-21 — SHA-512 pin on the preferred password path (#148)

**Scope.** From the same zen security pass as #149/#150: `um_password_write` preferred `chpasswd`, which hashes with the BusyBox build-time `CONFIG_FEATURE_DEFAULT_PASSWD_ALGO` (may be md5/des on some images/rebuilds) — the documented D6 control ("chpasswd/passwd -a sha512 fed on stdin only", security-audit-luci-login-2026-08-12:211) was not enforced on the preferred path.

**Fix.** `um_password_write` now verifies the stored shadow hash is `$6$` after every write (`um_user_hash_is_sha512`, field-anchored awk). A non-`$6$` result after `chpasswd` falls through to the pinned `passwd -a sha512` path, which is itself re-verified; if a weak hash still survives the write fails loudly (`password_hash_unverified`). Password never on argv in either path.

**Proof.** host: `tests/test_password_sha512_pin.sh` (shimmed chpasswd/passwd: `$6$` accepted without fallback; weak `$1$` triggers the pinned fallback with `-a sha512` argv proof; double-weak fails loudly; password absent from tool argv; no-chpasswd environment same discipline). Red on revert (6 assertions). Full `./scripts/smoke-host.sh` green incl. shellcheck. lab: none — no new lab surface.

### 2026-08-21 — Tampered LuCI logins fail closed (#150)

**Scope.** From the same zen security pass as #148/#149: when an owned login's ACL matrix no longer matches its role (e.g. /etc/config/rpcd edited to escalate a readonly login), classification correctly returned `tampered` but the login kept working with elevated ACLs until a manual reset — detection was passive, with only a UI badge. `usrmanage-health.sh` did not report it (and its schema is frozen — not touched).

**Fix.** `um_luci_login_state` now revokes the tampered user's live ubus SIDs on detection (best-effort, idempotent; no ACL rewrite — forensics preserved; no login deletion). Doctor gained a `luci_tampered` check reporting tampered owned logins at **error** severity (JSON + human output).

**Proof.** host: `tests/test_luci_login.sh` (#150 block — tampered fixture classified tampered; revoke observed via function override; clean owned state performs no revoke; doctor JSON/human error surfacing; clean config ok:true). Red on revert (revoke assertion fails). Full `./scripts/smoke-host.sh` green. lab: none — no new lab surface.

### 2026-08-22 — Diagnostic page RPCs for stock Status/Network (#156)

**Scope.** Readonly diagnostic menus advertised Status → Routing and Network → Interfaces/Routing/Diagnostics, but stock page JS needs methods that lived only under `luci-base` / `luci-base-network-status` (withheld on purpose). Menus showed; pages RPC-denied.

**Fix.** New read-only ACL group `luci-app-usrmanage-diagnostic-rpc`: `network.interface` `dump`, `network` `get_proto_handlers`, `uci` `get`/`changes`, `luci-rpc` `getBoardJSON`/`getHostHints`/`getNetworkDevices` — **not** `getWirelessDevices`, no `luci-base` file list, no write. Wired into readonly expected reads (diagnostic **9-set**). Upgrade migrate via luci-app `92-usrmanage-diagnostic-rpc` **and** usrmanage `91-usrmanage-diagnostic-rpc` (avoids luci-app/CLI package skew). `LUCI_EXTRA_DEPENDS` pins `usrmanage (>=0.1.13)` (not `LUCI_DEPENDS` — invalid Kconfig). Host contract pins all seven diagnostic-rpc methods; package-layout exact-allowlists the ACL object. QEMU asserts allow dump/uci get+changes and deny luci-base + getWirelessDevices. Playwright navigates the four pages with a post-paint settle before Access-denied asserts.

**Accepted residual.** Web-path `uci get`/`changes` over `luci-mod-network-config` packages (`network`, `wireless`, `dhcp`, `firewall`, `system`) — includes wireless PSK and network PPPoE secrets if present — plus `getHostHints` lease/neighbor hints required by stock Interfaces. Still no Overview SSID DOM path / `getWirelessDevices` / full `luci-base`.

**Proof.** `host`: contract (0 gaps) + luci-login 9-set + package-layout + `./scripts/smoke-host.sh` green. `lab` (2026-08-22, guest 24.10.8 + packages 0.1.13): `./scripts/qemu-smoke-usrmanage.sh` PASSED (dump/uci get+changes allow; luci-base + getWirelessDevices deny); Playwright `#156` 4/4.

### 2026-08-23 — rpcd `show` write-ACL gate (#158)

**Scope.** Read-only security pass follow-on to #149: diagnostic/read-only sessions could call `show <name>` for any system user and receive uid/gid/home/shell details — a per-name existence probe bypassing the `list --all` gate.

**Fix.** `show` in the rpcd plugin now requires `session_has_write_acl` (same probe as #149). Sessions without write ACL receive `{"ok":false,"error":"access_denied"}` without invoking the CLI (no `not_found` existence oracle). LuCI does not call `show`; managed-user detail is already available via plain `list`.

**Proof.** `host`: `tests/test_rpcd_show_acl.sh` (write ACL forwards / readonly+no-ubus+bad-SID fail closed without CLI); full `./scripts/smoke-host.sh` green. `lab`: none — no new guest surface.

## Review procedure

1. Read this file and [threat-model.md](threat-model.md) first. Do not reopen the #3 won't-fix bucket or the [Accepted residuals](#accepted-residuals) without new evidence.
2. Pick the surface with the **oldest date in the [coverage map](#surface-coverage-map)**. A pass that only re-reads the CLI is a pass that finds nothing new. **New surfaces start dated on the feature PR** that introduces them — do not leave them undated until a later periodic pass.
3. Diff the surface against [Controls in force](#controls-in-force). Anything new — mutator, rpcd method, file-write path, workflow step, release input, session/ACL write — needs a named guard, a **proof class**, and a proof of that class, or it is a finding.
4. Re-run the gates in [How to re-verify](#how-to-re-verify-current-gates) and reproduce each finding before filing it. Findings in this repo are expected to come with the command that demonstrates them. Check dismissed CodeQL alerts too — a "new" finding may already have a recorded decision. Apply the **false-green rule**: DRY_RUN/stub skips are not proof of `lab`-class controls.
5. File one tracking issue per theme with the `security` label, using an ID table (`S1`, `R1`, `P1`) so the ledger and the issue can reference the same rows. One issue plus one PR per hardening batch.
6. In the same PR: append a dated entry under [Audit history](#audit-history), refresh the coverage map dates, and add or close rows in [Open findings](#open-findings). Closed rows move to [Resolved findings](#resolved-findings).
7. **Feature PR gate** (auth / session / password / rpcd / ACL / sudoers / signing): the same PR updates Controls in force + coverage map for touched surfaces. Design locks that need the guest require either (a) an automated `qemu-smoke` assertion in-tree, or (b) an open `security`/`bug` issue that **blocks release acceptance** — not a silent unchecked checkbox. Do not close the parent feature as fully accepted while lab locks remain open.
8. **Pre-merge review trigger:** any PR that adds a mutator, rpcd method, session/ACL write, or release/signing step gets a security-review pass against this ledger *before* merge (Cursor security-review / Bugbot when available), not only post-merge external MCR.
9. Sibling repos (e.g. fwlive) may share patterns; treat cross-repo notes as candidates, not as an audit of that repo.

## Related

- [security.md](security.md) — operator / deployment guidance
- [threat-model.md](threat-model.md) — assets, actors, abuse cases
- [developer/architecture.md](developer/architecture.md) — removal order, password path
- [developer/testing.md](developer/testing.md) — host smoke / QEMU / Playwright, incl. host prerequisites
- [binary-feed.md](binary-feed.md) — signed feed layout and operator install path
- [release.md](release.md) — tagging and the publish workflow
- [security-opus-luci-login-brief.md](security-opus-luci-login-brief.md) — Opus/read-only audit brief (LuCI login)
- [security-audit-luci-login-2026-08-12.md](security-audit-luci-login-2026-08-12.md) — 2026-08-12 deep-dive results
- [security-prevention-plan.md](security-prevention-plan.md) — PR gates / false-green prevention
- [security-resolution-plan.md](security-resolution-plan.md) — security resolution plan for #158 / #159 (2026-08-23)
- Open security work: the `security` label — <https://github.com/lucas-albers-lz4/usrmanage/labels/security>
