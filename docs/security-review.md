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
| CLI + shared library | `openwrt-feed/usrmanage/files/usr/sbin/usrmanage`, `files/usr/lib/usrmanage/usrmanage-lib.sh`, `usrmanage-luci-login.sh` | 2026-08-12 (exhaustive) | [#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) L4 · [#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) L5/L6 · [#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105) L1/L3 · [#106](https://github.com/lucas-albers-lz4/usrmanage/issues/106) L2 |
| rpcd plugin + ACL | `openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage`, `root/usr/share/rpcd/acl.d/` | 2026-08-12 (LuCI-login deep dive) | none new (ACL split re-confirmed) |
| LuCI view | `openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js` | 2026-08-12 (LuCI-login deep dive) | related: same-role Apply enables L1 ([#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105)) |
| On-device install surface | package Makefiles, `files/etc/` (sudoers, uci-defaults, UCI config, registry) | 2026-08-12 (exhaustive) | none in the shipped files; runtime mode handling is [#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) |
| CI workflows | `.github/workflows/`, `.github/dependabot.yml` | 2026-08-09 | none |
| Release + signing | `scripts/publish-packages.sh`, `scripts/lib/feed-keys.sh`, `scripts/lib/feed-publish.sh`, `scripts/validate-feed-keys.sh` | 2026-08-09 | none |
| Build inputs (SDK, feeds) | `scripts/lib/sdk-matrix.sh`, `scripts/feeds.lock/`, `docker-compose.yml` | 2026-08-12 | none |
| Operator trust bootstrap | `docs/binary-feed.md`, published feed keys | 2026-08-09 | none |
| QEMU lab + e2e | `scripts/qemu-*.sh`, `tests/e2e/`, `playwright.config.js` | 2026-08-12 (LuCI-login deep dive) | [#107](https://github.com/lucas-albers-lz4/usrmanage/issues/107) proveable_next (lab asserts) — fixtures remain lab-only by design |

## How to re-verify (current gates)

| Command | What it covers |
|---------|----------------|
| `./scripts/smoke-host.sh` | shellcheck, package layout, link check, validators, mutators-under-lock, rpcd argv (password-safe stub), busybox fallback, theme/i18n/parity |
| `python3 scripts/z3-verify.py --full` | Formal proof of username / actor grammars (empty, length, deny-list, injection alphabet) |
| `./scripts/qemu-smoke-usrmanage.sh` | Live OpenWrt guest: doctor → add/list/set-role/passwd/del → audit → last-admin → **LuCI session revoke** (create session → disable → SID destroyed) → LuCI/ubus |
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
| Password in argv / `ps` / logs | `--password-fd` or stdin; rpcd pipes fd 0; never audit/syslog | host | `tests/test_mutators.sh` stub argv |
| Audit field injection (actor/src) | Whitelist + 64-char cap (`um_actor_resolve`, `sanitize_actor`); audit tokens may contain `=` but never a space, so no new field can be introduced | host | #3 C1 · Z3 P2 |
| Unquoted argv rpcd → CLI | Explicit argv per ubus method | host | #3 C2 · `tests/test_mutators.sh` |
| View → manage escalation | Split rpcd ACL; server authoritative | host | `acl.d/luci-app-usrmanage.json` |
| Non-root mutators | `um_require_root` before manage commands | host | `tests/test_validators.sh` |
| XSS via username / audit text in LuCI | DOM via LuCI `E()`; no `innerHTML` | manual | Manual review of `usrmanage.js` |

### Integrity / login safety

| Failure scenario | Guard | Class | Proof |
|------------------|-------|-------|-------|
| Concurrent mutators on account files | Whole-mutator exclusive `flock` (`um_with_lock`) | host | `tests/test_mutators.sh`. Open: the lock file is world-readable, so an unprivileged local user can hold it indefinitely — [#111](https://github.com/lucas-albers-lz4/usrmanage/issues/111) L7 |
| Crash mid-mutation | Snapshot / EXIT rollback (`um_tx_*`) over passwd+shadow+group+registry+rpcd (create/delete/set-role). Del commits BEFORE `um_registry_del` (purge may remove the home) — the post-commit registry window is covered by the `incomplete` marker, not the snapshot | host | `tests/test_phase1_foundation.sh` · `tests/test_luci_login.sh` |
| Torn file writes | `umask 077` temp → fixed mode/`chown 0:0` → `mv` (`um_atomic_edit`). **Not universal:** `um_rpcd_atomic_replace` and `um_audit_rotate_if_needed` bypass it ([#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) L5/L6) | host | `tests/test_phase1_foundation.sh` — no test asserts resulting **modes** |
| SIGKILL / power loss mid-mutation | **Accepted residual**: EXIT-trap rollback cannot run; `doctor` reports orphaned `usrmanage-tx.*` snapdirs for manual recovery. Snapdirs live in `${TMPDIR:-/tmp}` (tmpfs) — recovery applies only if the snapshot survives until the operator acts (#96, #100) | host | `um_doctor_checks` |
| Demote/delete last managed admin | `um_count_managed_admins` deny | host | `tests/test_mutators.sh` · QEMU smoke |
| Incomplete op with no record | `incomplete` marker + `doctor`; failed restore keeps snapdir | host | `um_doctor_checks` · architecture docs |
| Broken sudoers fragment | Minimal static `%wheel` rule; `doctor` runs `visudo -cf` | host | `um_doctor_checks` |
| Upgrade/remove wiping managed state | `users`, sudoers, UCI config are conffiles | host | package Makefile |

### LuCI login lifecycle

| Failure scenario | Guard | Class | Proof |
|------------------|-------|-------|-------|
| Empty / locked shadow accepted for web login | Refuse enable when hash empty or `!`/`*` | host | `tests/test_luci_login.sh` |
| Adopt foreign / tampered `luci-app-acl` login | Ownership conjunction (`usrmanage=1` + `$p$user` + managed registry) — **holds only for canonical UCI syntax**; see [#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) L4 | host | `tests/test_luci_login.sh` |
| Login section written in a libuci-valid form the awk parser cannot see | **Open** — indented / `c`-abbreviated / quoted-type sections invisible; `disable` reports `ok` while the login authenticates ([#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) L4) | host | pending fail-closed validator or `uci`-based enumeration |
| `/etc/config/rpcd` mode preserved on rewrite / rollback | **Open** — hardcoded `chmod 0644` downgrades OpenWrt's `0600` ([#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) L5) | host | pending mode-preserving replace + mode assertion test |
| Live session keeps old ACLs after disable / role / del / passwd | `um_session_revoke_user` destroys matching ubus SIDs (`@.values.username` then `@.data.username`) | lab | `scripts/qemu-smoke-usrmanage.sh` (issue #95) — host DRY_RUN skips ubus and is **not** proof |
| Same-role / ACL-repair `set-role` leaves elevated live sessions | **Open** — sync via `um_luci_login_ours_index` without revoke ([#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105) L1) | host (+ lab) | pending fix + test |
| `set-luci-login` multi-index rewrite crash window | **Open** — incomplete marker only; no `um_tx_*` ([#106](https://github.com/lucas-albers-lz4/usrmanage/issues/106) L2) | host | pending fix + test |
| New `session.login` denied after disable; demote drops write on re-login | **Open proveable_next** ([#107](https://github.com/lucas-albers-lz4/usrmanage/issues/107)) | lab | extend qemu-smoke |
| rpcd pending UCI changes during enable/disable | Refuse when `uci changes rpcd` non-empty | host | `tests/test_luci_login.sh` |

### Supply chain

| Failure scenario | Guard | Class | Proof |
|------------------|-------|-------|-------|
| Unsigned or third-party-signed feed | opkg `usign` + apk RSA signing in the publish job; keys validated before use | host | `scripts/validate-feed-keys.sh` |
| Signing secret leaking into the published feed | Staging copies public key material only | host | `feed_publish_copy_keys` |
| Silently altered build inputs | Pinned SDK matrix and `scripts/feeds.lock/` feed pins (see [#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63) R4 for the remaining mutable pins) | host | `sdk_matrix_feeds_ready` lock stamp |
| Non-reproducible release artifacts | `SOURCE_DATE_EPOCH` from the tag commit + repro gate | host | `scripts/verify-reproducible-build.sh` |

## Open findings

From the 2026-08-12 exhaustive pass ([security-audit-luci-login-2026-08-12.md](security-audit-luci-login-2026-08-12.md)). All reproduced locally. Implement via simpler-model PRs; use `/review-security` on those PRs.

**Implementation order: #109 → #108 → #106 → #105 (L3 then L1) → #107.**

| Issue | IDs | Severity | Area | Notes |
|-------|-----|----------|------|-------|
| [#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) | L5, L6 | Medium / Low | On-device file modes | `/etc/config/rpcd` force-chmod `0644` over OpenWrt's `0600` (`INSTALL_CONF`); audit rotate ignores umask. Same class as #63 R2, never swept on-device |
| [#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) | L4 | Medium | Ownership / revocation | awk parser narrower than libuci (indented / `c`-abbreviated / quoted-type sections invisible) — `disable` reports `ok` while the login still authenticates |
| [#106](https://github.com/lucas-albers-lz4/usrmanage/issues/106) | L2 | Low-Med | Integrity | `set-luci-login` lacks tx snapshot for multi-index rpcd rewrite |
| [#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105) | L1, L3 | Low | Session ACL / DiD | Same-role set-role sync without revoke (severity revised down); `um_shadow_hash_usable` missing `grep -F` |
| [#107](https://github.com/lucas-albers-lz4/usrmanage/issues/107) | P1, P2 | — | Lab proof | Post-disable login deny + demote write-ACL drop asserts; blocked on #108 |
| [#111](https://github.com/lucas-albers-lz4/usrmanage/issues/111) | L7 | Low-Med | On-device file modes / availability | `/var/lock/usrmanage.lock` created 0644 by `9>`; `flock(2)` works on a read-only fd, so a managed unprivileged user can hold it and block every mutator — including their own revocation — until reboot |

Prior Aug-9 findings are resolved.

## Resolved findings

Resolved by the audit remediation wave. Close the tracking issue when the fix lands.

| Issue | Area | Resolved by |
|-------|------|-------------|
| [#61](https://github.com/lucas-albers-lz4/usrmanage/issues/61) S1/S3/S4 | CLI / rpcd | [PR #80](https://github.com/lucas-albers-lz4/usrmanage/pull/80) — `grep -F` username lookups, rpcd session hex whitelist, role resolution before audit |
| [#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63) R1–R5 | CI / release | [PR #78](https://github.com/lucas-albers-lz4/usrmanage/pull/78) + [PR #79](https://github.com/lucas-albers-lz4/usrmanage/pull/79) + [PR #82](https://github.com/lucas-albers-lz4/usrmanage/pull/82) — env-routing, usign key 0600, SHA-pins + actionlint gate, tooling pins |
| [#64](https://github.com/lucas-albers-lz4/usrmanage/issues/64) | Operator trust | [PR #81](https://github.com/lucas-albers-lz4/usrmanage/pull/81) — key fingerprints published in the README, [binary-feed.md](binary-feed.md), and the feed README. Install snippets verify the SHA-256. |
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
| No `flock -w` timeout | BusyBox constraint; see #61 S2 for optional diagnostics. **Narrowed 2026-08-12:** this was accepted on the premise that a stuck holder is a *trusted* process that will eventually exit. It is not — the lock file is 0644, so any local UID can become the holder deliberately ([#111](https://github.com/lucas-albers-lz4/usrmanage/issues/111) L7). The BusyBox constraint stays accepted; the reachability does not |
| UI `hasWriteAcl` best-effort | Server ACL is authoritative |
| Best-effort process kill on delete | Account lock still blocks new logins |
| Admin role means full root via sudo | Product lock, by design — see [AGENTS.md](../AGENTS.md) |
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
- Open security work: the `security` label — <https://github.com/lucas-albers-lz4/usrmanage/labels/security>
