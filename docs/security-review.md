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
| CLI + shared library | `openwrt-feed/usrmanage/files/usr/sbin/usrmanage`, `files/usr/lib/usrmanage/usrmanage-lib.sh` | 2026-08-09 | none |
| rpcd plugin + ACL | `openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage`, `root/usr/share/rpcd/acl.d/` | 2026-08-09 | none |
| LuCI view | `openwrt-feed/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js` | 2026-08-09 | none |
| On-device install surface | package Makefiles, `files/etc/` (sudoers, uci-defaults, UCI config, registry) | 2026-08-09 | none |
| CI workflows | `.github/workflows/`, `.github/dependabot.yml` | 2026-08-09 | none |
| Release + signing | `scripts/publish-packages.sh`, `scripts/lib/feed-keys.sh`, `scripts/lib/feed-publish.sh`, `scripts/validate-feed-keys.sh` | 2026-08-09 | none |
| Build inputs (SDK, feeds) | `scripts/lib/sdk-matrix.sh`, `scripts/feeds.lock/`, `docker-compose.yml` | 2026-08-09 | none |
| Operator trust bootstrap | `docs/binary-feed.md`, published feed keys | 2026-08-09 | none |
| QEMU lab + e2e | `scripts/qemu-*.sh`, `tests/e2e/`, `playwright.config.js` | 2026-08-09 | none — lab-only fixtures and passwords are by design, never shipped |

## How to re-verify (current gates)

| Command | What it covers |
|---------|----------------|
| `./scripts/smoke-host.sh` | shellcheck, package layout, link check, validators, mutators-under-lock, rpcd argv (password-safe stub), busybox fallback, theme/i18n/parity |
| `python3 scripts/z3-verify.py --full` | Formal proof of username / actor grammars (empty, length, deny-list, injection alphabet) |
| `./scripts/qemu-smoke-usrmanage.sh` | Live OpenWrt guest: doctor → add/list/set-role/passwd/del → audit → last-admin → LuCI/ubus |
| `gh api repos/:owner/:repo/code-scanning/alerts` | CodeQL findings, **including dismissed ones** — check before filing, a finding may already have a decision |

Notes:

- Z3 proves **input grammars**. Last-admin arithmetic and the lock/tx state machine are covered by **host tests** on the real shell, not yet by a formal model.
- CodeQL runs via GitHub **default setup** (`actions`, `javascript-typescript`, `python`, extended suite), so there is no workflow file for it in this repo. Its `actions` queries cover unpinned action tags but treat `workflow_dispatch` inputs as trusted.
- Host prerequisites and the macOS gaps live in [developer/testing.md](developer/testing.md#host-smoke) — do not restate them here.

## Controls in force

Living reference, not a snapshot of one review. A new mutator, rpcd method, file-write path, or release step is not done until it has a named guard in one of these tables and a proof.

### Exploit

| Attack surface | Guard | Proof |
|----------------|-------|-------|
| Shell / command injection via username | Strict charset (`a-z0-9_-`, 1–32, deny-list) gates mutators and `show` | `tests/test_validators.sh` · Z3 P1 |
| Password in argv / `ps` / logs | `--password-fd` or stdin; rpcd pipes fd 0; never audit/syslog | `tests/test_mutators.sh` stub argv |
| Audit field injection (actor/src) | Whitelist + 64-char cap (`um_actor_resolve`, `sanitize_actor`); audit tokens may contain `=` but never a space, so no new field can be introduced | #3 C1 · Z3 P2 |
| Unquoted argv rpcd → CLI | Explicit argv per ubus method | #3 C2 · `tests/test_mutators.sh` |
| View → manage escalation | Split rpcd ACL; server authoritative | `acl.d/luci-app-usrmanage.json` |
| Non-root mutators | `um_require_root` before manage commands | `tests/test_validators.sh` |
| XSS via username / audit text in LuCI | DOM via LuCI `E()`; no `innerHTML` | Manual review of `usrmanage.js` |

### Integrity / login safety

| Failure scenario | Guard | Proof |
|------------------|-------|-------|
| Concurrent mutators on account files | Whole-mutator exclusive `flock` (`um_with_lock`) | `tests/test_mutators.sh` |
| Crash mid-mutation | Snapshot / EXIT rollback (`um_tx_*`) over passwd+shadow+group+registry | `tests/test_phase1_foundation.sh` |
| Torn file writes | `umask 077` temp → fixed mode/`chown 0:0` → `mv` | `tests/test_phase1_foundation.sh` |
| Demote/delete last managed admin | `um_count_managed_admins` deny | `tests/test_mutators.sh` · QEMU smoke |
| Incomplete op with no record | `incomplete` marker + `doctor`; failed restore keeps snapdir | `um_doctor_checks` · architecture docs |
| Broken sudoers fragment | Minimal static `%wheel` rule; `doctor` runs `visudo -cf` | `um_doctor_checks` |
| Upgrade/remove wiping managed state | `users`, sudoers, UCI config are conffiles | package Makefile |

### Supply chain

| Failure scenario | Guard | Proof |
|------------------|-------|-------|
| Unsigned or third-party-signed feed | opkg `usign` + apk RSA signing in the publish job; keys validated before use | `scripts/validate-feed-keys.sh` |
| Signing secret leaking into the published feed | Staging copies public key material only | `feed_publish_copy_keys` |
| Silently altered build inputs | Pinned SDK matrix and `scripts/feeds.lock/` feed pins (see [#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63) R4 for the remaining mutable pins) | `sdk_matrix_feeds_ready` lock stamp |
| Non-reproducible release artifacts | `SOURCE_DATE_EPOCH` from the tag commit + repro gate | `scripts/verify-reproducible-build.sh` |

## Open findings

None. All findings from the 2026-08-09 passes are resolved. See [Resolved findings](#resolved-findings) below. The one deferred item, [#61](https://github.com/lucas-albers-lz4/usrmanage/issues/61) S2 (no `flock -w` wait timeout), is an accepted BusyBox constraint. See [Accepted residuals](#accepted-residuals).

## Resolved findings

Resolved by the audit remediation wave. Close the tracking issue when the fix lands.

| Issue | Area | Resolved by |
|-------|------|-------------|
| [#61](https://github.com/lucas-albers-lz4/usrmanage/issues/61) S1/S3/S4 | CLI / rpcd | [PR #80](https://github.com/lucas-albers-lz4/usrmanage/pull/80) — `grep -F` username lookups, rpcd session hex whitelist, role resolution before audit |
| [#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63) R1–R5 | CI / release | [PR #78](https://github.com/lucas-albers-lz4/usrmanage/pull/78) + [PR #79](https://github.com/lucas-albers-lz4/usrmanage/pull/79) + [PR #82](https://github.com/lucas-albers-lz4/usrmanage/pull/82) — env-routing, usign key 0600, SHA-pins + actionlint gate, tooling pins |
| [#64](https://github.com/lucas-albers-lz4/usrmanage/issues/64) | Operator trust | [PR #81](https://github.com/lucas-albers-lz4/usrmanage/pull/81) — key fingerprints published in the README, [binary-feed.md](binary-feed.md), and the feed README. Install snippets verify the SHA-256. |
| [#65](https://github.com/lucas-albers-lz4/usrmanage/issues/65) P1/P2 | Product | [PR #83](https://github.com/lucas-albers-lz4/usrmanage/pull/83) — test-only env-override gate and multi-line / control-char password rejection |
| [#66](https://github.com/lucas-albers-lz4/usrmanage/issues/66) | Tooling | [PR #84](https://github.com/lucas-albers-lz4/usrmanage/pull/84) — portable stat helper, flock shim, and skip reasons. The full gate runs on macOS. |

## Accepted residuals

Do not re-open without new evidence.

| Accepted risk | Rationale |
|---------------|-----------|
| Password traverses ubus JSON once (LuCI → rpcd) | Platform pattern (same as stock LuCI `setPassword`); TLS ops guidance; never argv/logs after |
| Local `audit.log` not tamper-evident | Root can rewrite any local file; operational claim only |
| `userdel -r` may follow symlinked home on purge | Matches stock tools; avoid `--purge-home` on untrusted homes |
| No `flock -w` timeout | BusyBox constraint; see #61 S2 for optional diagnostics |
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
| Lock → kill → delete sequence | Pass — `um_mut_del` |
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

## Review procedure

1. Read this file and [threat-model.md](threat-model.md) first. Do not reopen the #3 won't-fix bucket or the [Accepted residuals](#accepted-residuals) without new evidence.
2. Pick the surface with the **oldest date in the [coverage map](#surface-coverage-map)**. A pass that only re-reads the CLI is a pass that finds nothing new.
3. Diff the surface against [Controls in force](#controls-in-force). Anything new — mutator, rpcd method, file-write path, workflow step, release input — needs a named guard and a proof, or it is a finding.
4. Re-run the gates in [How to re-verify](#how-to-re-verify-current-gates) and reproduce each finding before filing it. Findings in this repo are expected to come with the command that demonstrates them. Check dismissed CodeQL alerts too — a "new" finding may already have a recorded decision.
5. File one tracking issue per theme with the `security` label, using an ID table (`S1`, `R1`, `P1`) so the ledger and the issue can reference the same rows. One issue plus one PR per hardening batch.
6. In the same PR: append a dated entry under [Audit history](#audit-history), refresh the coverage map dates, and add or close rows in [Open findings](#open-findings). Closed rows move to [Resolved findings](#resolved-findings).
7. Sibling repos (e.g. fwlive) may share patterns; treat cross-repo notes as candidates, not as an audit of that repo.

## Related

- [security.md](security.md) — operator / deployment guidance
- [threat-model.md](threat-model.md) — assets, actors, abuse cases
- [developer/architecture.md](developer/architecture.md) — removal order, password path
- [developer/testing.md](developer/testing.md) — host smoke / QEMU / Playwright, incl. host prerequisites
- [binary-feed.md](binary-feed.md) — signed feed layout and operator install path
- [release.md](release.md) — tagging and the publish workflow
- Open security work: the `security` label — <https://github.com/lucas-albers-lz4/usrmanage/labels/security>
