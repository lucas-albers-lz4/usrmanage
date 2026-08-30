# Security audit — 2026-08-12 (LuCI login + on-device file discipline)

Read-only pass against the brief in [security-opus-luci-login-brief.md](security-opus-luci-login-brief.md).
Ledger: [security-review.md](../security-review.md). No remediation code was written in this pass.

Scope actually read line by line: `usrmanage` CLI arg parser, `usrmanage-lib.sh`,
`usrmanage-luci-login.sh`, rpcd plugin, `acl.d/luci-app-usrmanage.json`, LuCI view,
package Makefile / uci-defaults / sudoers, CI workflows. Cross-checked against upstream
OpenWrt `rpcd/session.c`, `libuci/file.c`, and `rules.mk`.

Every finding below was **reproduced locally** with the harness described in
[Reproduction](#reproduction) — not inferred from reading alone.

## 1. Architecture verdict

Ownership model: a LuCI login is *ours* iff `usrmanage=1` ∧ password `$p$<user>` ∧ user in
the managed registry ∧ ACL list matches the role matrix. Everything else is
`foreign` / `tampered` and must never be adopted. Ordering invariants established by
#92–#101 hold as written:

| Path | Order | Verdict |
|------|-------|---------|
| `um_mut_passwd` | policy validate → revoke → shadow commit | correct (#92) |
| `um_mut_del` | tx → revoke → drop owned login → lock → kill → wheel → delete → commit → registry | correct (#94) |
| Demote | revoke → sync ACLs → drop wheel | correct fail-safe direction (#96) |
| Promote | wheel → sync ACLs → revoke | correct |
| Disable / reset | revoke → remove marked sections | correct (#98 m4 respected) |

**The weak point is not the ordering — it is the trust placed in an ad-hoc parser and in
unconditional file modes.** Both the ownership model (L4) and the "atomic replace with
fixed mode" invariant (L5) are implemented in ways that diverge from the platform they
model. That is the structural theme of this pass.

## 2. Defense-in-depth gaps (ranked)

1. **L4** — ownership/revocation decisions are made by an awk parser that recognizes a
   *narrower* grammar than libuci. Sections rpcd honors can be invisible to usrmanage,
   so `disable` can report success while the login still works.
2. **L5** — `/etc/config/rpcd` is force-chmod'ed to `0644`; OpenWrt ships it `0600`.
3. **L2** — `set-luci-login` mutates rpcd outside `um_tx_*` (crash window).
4. **L1** — same-role `set-role` repairs ACL drift without revoking live sessions.
5. **L6** — audit rotation writes its temp under the ambient umask (same class as L5).
6. No lab assertion that a *new* `session.login` is refused after `disable` (#107).

## 3. Provability matrix

| Property | Class | Artifact / next step |
|----------|-------|----------------------|
| Empty / `!` / `*` shadow refused on enable | `already_proven` | `tests/test_luci_login.sh` |
| Foreign / tampered not adopted (**canonical UCI syntax only**) | `already_proven` | host tests — see L4 for the grammar hole |
| Disable destroys live SID | `already_proven` | qemu-smoke (#95 / PR #103) |
| Disable actually removes the login definition | **cannot-prove today** | blocked on L4; needs a parser that matches libuci |
| `/etc/config/rpcd` mode preserved | **cannot-prove today** | no test asserts mode; add one with L5 |
| New `session.login` refused after disable | `prove-next` | qemu assert (#107 P1) |
| Demote drops write ACL on re-login | `prove-next` | qemu assert (#107 P2) |
| Same-role repair revokes sessions | `prove-next` | host test after L1 fix |
| `set-luci-login` crash-atomic | `prove-next` | tx wrap + host test (L2) |
| Tx covers rpcd on add/del/set-role | `already_proven` | host M3/M5 tests |
| View ACL cannot reach write methods | `already_proven` | `acl.d/luci-app-usrmanage.json` |
| Password never on argv; multi-line rejected | `already_proven` | mutator + rpcd tests |
| No XSS sink in the view | `already_proven` | no `innerHTML` / `eval` in the package |
| ubus password hop, CSRF, root forging audit | `cannot-prove` | accepted residuals — unchanged |

## 4. Findings

### L4 — Medium — `disable` / `del` silently miss libuci-valid login sections

**Mechanism.** `um_rpcd_login_dump` (`usrmanage-luci-login.sh:99`) detects section headers
with `/^config[ \t]+login([ \t]|$)/` — anchored at column 0, keyword spelled in full,
type unquoted. libuci is more permissive:

- `uci_parse_line()` calls `skip_whitespace()` **before** dispatching, so an indented
  `config login` is a real section (`libuci/file.c:508-514`).
- The keyword may be abbreviated to a single letter: `case 'c': if ((word[1] == 0) || !strcmp(word + 1, "onfig"))`
  — so `c login` / `o username` / `l read` are valid (`libuci/file.c:520-547`).
- The section type goes through `next_arg()` → `parse_str()`, so `config 'login'` is valid
  (`libuci/file.c:434`, `:247`).

Any login section written in one of those forms is invisible to
`um_luci_login_state`, `um_luci_login_ours_index`, and
`um_luci_login_remove_owned_best_effort`, while rpcd authenticates against it normally.

**Blast radius.**

- `set-luci-login <user> --disable` returns `ok`, audits `luci_revoke … result=ok reason=acl=none`,
  and the LuCI table shows `luci_login: none` — while the user can log straight back in.
  Live sessions *are* destroyed, which makes the failure look like a success.
- `del` removes the UNIX account but leaves the section. If it carries a crypt hash rather
  than `$p$user` (rpcd supports both — `rpc_login_test_password()` falls through to
  `crypt(password, hash)`), the web credential **survives account deletion** with whatever
  ACLs it lists.
- `add --luci-login` / `enable`: the `login_exists_foreign` guard sees `none`, so usrmanage
  appends its own section alongside the hidden one. `rpc_login_test_login()` returns the
  first matching section, so the hidden ACLs can win while `verify_owned_acls` checks only
  usrmanage's own section and reports success.

The realistic threat is not a typo: it is an attacker who had root once and wants a web
login that survives "we disabled that account" and stays invisible in the UI.

**Proposed fix.** Do not hand-parse a libuci file. Preferred: enumerate and mutate via
`uci` (`uci -q show rpcd`, `uci delete rpcd.@login[N]`, `uci add rpcd login`, `uci commit rpcd`),
which is already a soft dependency (`um_rpcd_pending_ok`). Minimum viable, ash-safe
alternative: a **fail-closed pre-flight validator** called at the top of
state/enable/disable/reset that refuses to operate (`UM_LUCI_ERR=rpcd_config_unparsable`,
audit `denied`) when `/etc/config/rpcd` contains a line libuci would honor but the awk
grammar cannot see:

- `^[[:space:]]\+config[[:space:]]` — indented section header
- `^[[:space:]]*[col][[:space:]]` — abbreviated `c` / `o` / `l` keyword
- `^config[[:space:]]\+["']` — quoted section type

Never report `none` for a file the parser does not fully understand.

**Re-verify.** `./scripts/smoke-host.sh` plus a new host test per form (indented, `c login`,
quoted type): state must be `foreign`/error and `disable` must not report `ok`.
**Proof class after fix:** `host`.

### L5 — Medium — `/etc/config/rpcd` permissions downgraded 0600 → 0644

**Mechanism.** `um_rpcd_atomic_replace` (`usrmanage-luci-login.sh:352-362`) stages a temp
file and applies a hardcoded `chmod 0644` before `mv`, ignoring the destination's actual
mode. `um_tx_restore_one` (`usrmanage-lib.sh:697`) does the same on rollback
(`passwd|group|rpcd) chmod 0644`). Upstream OpenWrt installs this file with
`$(INSTALL_CONF)`, i.e. `install -m0600` (`rules.mk`, `package/system/rpcd/Makefile:64`).

So the **first** `set-luci-login` on a stock device permanently world-readables
`/etc/config/rpcd`. No precondition, no misconfiguration required.

**Blast radius.** Every local user — including precisely the unprivileged SSH accounts this
package exists to provision — can then read the rpcd login table: usernames, ACL grants,
and any non-`$p$` **crypt hashes** stored by other principals (an ordinary pattern for
API-only rpcd accounts). Hash disclosure enables offline cracking and credential reuse.
It also silently contradicts the documented invariant in
[security.md](../security.md#account-file-write-safety-v013) that atomic replaces end at a
*fixed, correct* mode.

This is the same defect class as [#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63)
R2 (temp-file mode winning over the destination), which was fixed in the release pipeline
but never swept across the on-device write paths.

**Proposed fix.** Capture the destination mode before replacing and restore it
(`um_stat_mode`-style helper already exists for tests), defaulting to `0600` for
`USRMANAGE_RPCD_CONFIG` when the file does not exist yet. Change the `rpcd` arm of
`um_tx_restore_one` from `0644` to the captured/`0600` value. Do not reuse the
`passwd|group` arm for rpcd.

**Re-verify.** Host test: `chmod 0600` the fixture, run enable/disable/reset and a forced
rollback, assert mode is still `0600` after each. `./scripts/smoke-host.sh`.
**Proof class after fix:** `host`.

### L2 — Low-Medium — `set-luci-login` rewrites rpcd outside the tx snapshot

**Mechanism.** `um_mut_set_luci_login` (`usrmanage-luci-login.sh:715`) sets only the
`incomplete` marker; it never calls `um_tx_begin`. Disable and reset rewrite the file once
per matching index in a loop (`:529-547`, `:650-667`). A SIGKILL mid-loop can leave a
subset of marked sections in place.

**Blast radius.** Crash or power loss during multi-section cleanup leaves a login that
still authenticates until the next `reset`/`doctor`. Not remotely triggerable.

**Proposed fix.** Wrap enable/disable/reset in `um_tx_begin` / `um_tx_commit` (rpcd is
already in the snapshot set), or emit the whole file in a single pass instead of N
rewrites. Surface stale `luci-login:*` incomplete markers in `doctor`.

**Re-verify.** Host incomplete-marker test; `./scripts/smoke-host.sh`.
**Proof class after fix:** `host`.

### L1 — Low (revised from Medium) — same-role `set-role` repairs ACLs without revoking

**Mechanism.** `um_luci_login_ours_index` matches marker + `$p$user` + managed **without**
checking the ACL matrix, so a drifted section counts as "ours".
`_um_set_role_sync_acls` (`usrmanage-lib.sh:1753`) therefore runs on the same-role branch
(`:1806-1810`), which calls sync but **not** `_um_set_role_revoke`. The LuCI
`handleSetRole` modal allows re-applying the current role.

**Blast radius.** On-disk ACLs are repaired while live ubus sessions keep the elevated
grants until logout. **Severity revised down:** establishing the drift requires a root-level
write to `/etc/config/rpcd` in the first place, so this is hardening of a repair path, not
a privilege boundary. Reproduced state (`tampered`, non-empty `ours_index`, role
`readonly`) shows that the branch is reachable.

**Proposed fix.** Revoke whenever `um_luci_login_sync_acls` actually rewrote rpcd — including
the same-role branch — and fail closed on revoke failure like the other arms.

**Re-verify.** Host test seeding a drifted owned section, then same-role `set-role`.
**Proof class after fix:** `host` (optionally `lab`).

### L6 — Low — audit rotation temp inherits the ambient umask

**Mechanism.** `um_audit_rotate_if_needed` (`usrmanage-lib.sh:583-593`) does
`tail -c … > "${USRMANAGE_AUDIT}.1"` under the ambient umask, `mv`s it over `audit.log`,
then chmods. No `umask 077` subshell and no `chown 0:0`, unlike `um_atomic_edit`.

**Blast radius.** Contained: `/var/log/usrmanage` is `0750 root:root`, so the window is not
reachable by unprivileged users today. It is a latent instance of the L5 class and it
diverges from the documented write discipline.

**Proposed fix.** Wrap the `tail` redirect in a `umask 077` subshell and `chown 0:0` before
`mv`, mirroring `um_atomic_edit`.

**Re-verify.** Host test asserting mode/owner after a forced rotation.
**Proof class after fix:** `host`.

## 5. Explicit non-findings (checked, still holding)

- CLI argument parser: attacker-controlled `name` from ubus cannot smuggle a second
  positional; value-taking options consume the following token and fail closed.
- rpcd plugin: explicit argv per method, `jsonfilter` required, session id hex-whitelisted,
  password extracted via temp file + two sequential reads on one fd (trailing-newline
  truncation genuinely rejected), actor sanitized to `[A-Za-z0-9._@-]` ≤ 64.
- Password never on argv; `chpasswd`/`passwd -a sha512` fed on stdin only.
- Audit token grammar permits `=` but never a space — no field injection (#3 C1 intact).
- LuCI view: no `innerHTML` / `outerHTML` / `eval` / `document.write` anywhere in the package.
- ACL split is correct; `get_policy`/`set_policy` sit on the write side by design.
- Env-override gate is inert without `USRMANAGE_TEST_OVERRIDES=1`.
- `um_home_create` / `um_home_remove` refuse symlinks; `um_mut_fail` never removes a
  pre-existing home.
- Sudoers fragment is static `%wheel` with no NOPASSWD; installed `0440`, checked by `doctor`.
- CI: all actions SHA-pinned, dispatch input routed via `env:`, no `pull_request_target`.
- Shadow/passwd/group lookups use `grep -F` in the lib.

## 6. Reproduction

Throwaway harness (nothing written to the repo): source the lib with
`USRMANAGE_TEST_OVERRIDES=1` and temp paths, seed a managed `ops` user, then:

| Repro | Result |
|-------|--------|
| `chmod 0600` rpcd fixture → `um_luci_login_enable_user ops` → `stat -c %a` | `600` → **`644`**; foreign `$1$…` hash now world-readable |
| Indented `config login` for `ops` → `um_luci_login_state ops` | **`none`** (expected `foreign`) |
| … then `um_mut_set_luci_login ops disable` | prints `ok`, audits `luci_revoke … result=ok`, **section still present** |
| `c login` / `o username` form → `um_rpcd_login_dump` | **empty** (section invisible) |
| Drifted owned section, readonly user | `state=tampered`, `ours_index=0` → same-role sync path reachable |

## 7. Issue filing plan

| Issue | IDs | Priority | Depends on |
|-------|-----|----------|------------|
| [#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105) | L1, L3 | L3 trivial; L1 low | — |
| [#106](https://github.com/lucas-albers-lz4/usrmanage/issues/106) | L2 | medium-low | — |
| [#107](https://github.com/lucas-albers-lz4/usrmanage/issues/107) | P1, P2 | lab proof | after L4 |
| [#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108) | L4 | **first** | — |
| [#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109) | L5, L6 | **second** | — |

Suggested order for implementation by cheaper models: **L5/L6 → L4 → L2 → L3 → L1 → #107**.
L5 is mechanical and removes an active on-device exposure; L4 is the correctness fix that
makes the revocation claim true and unblocks the #107 lab asserts.

## 8. Prevention notes

Both new findings are *classes*, not one-offs, and both were invisible to the existing
gates. See [security-prevention-plan.md](security-prevention-plan.md):

- No test asserts the **mode** of any file usrmanage rewrites. A control that says "fixed
  mode" needs a mode assertion, not a comment.
- #63 R2 was fixed in the release pipeline but the identical temp-file/mode defect
  survived on-device. Findings should trigger a **repo-wide sweep of the class**, recorded
  in the ledger, not just a fix at the reported site.
- Any hand-written parser for a platform format (UCI, passwd, shadow) is a security
  control and must either use the platform tool or fail closed on input it cannot fully
  model.
