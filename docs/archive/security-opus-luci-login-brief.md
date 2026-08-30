# Opus-high brief — LuCI login security audit (read-only)

**Audience:** `claude-opus-5-thinking-high` Task agent  
**Repo root:** `/home/lalbers/gitroot/usrmanage`  
**Mode:** read-only audit. **Do not edit files, commit, or open PRs.**  
**Product of this pass:** well-defined findings ready to become GitHub `security` issues that a simpler model can implement. You examine code in depth; you do **not** write remediation patches.

---

## Mission

Audit the **LuCI login lifecycle / session revoke / ACL** architecture for:

1. Remaining security bugs (exploit, integrity/lockout, privilege mistakes).
2. Defense-in-depth gaps (primary guard holds but next layer is thin).
3. What is already proven vs what can be made **provably** secure next vs what is a platform residual.

This package manages OpenWrt local UNIX users with readonly vs admin (`wheel`+sudo). Correctness of authz/session/password paths is load-bearing.

## Priority and scope locks

- **Codebase audit first**; prevention recommendations second (brief section only).
- **Focus:** LuCI login surface (post-#95 hot zone). Do not re-litigate full pre-LuCI CLI, supply-chain #63/#64, or Accepted residuals / #3 won’t-fix **without new evidence**.
- Hop outside LuCI login only if a finding forces it (cite why).

## Mandatory reads (in order)

1. `docs/security-review.md` — coverage map, controls + proof class, false-green rule, process failures 2026-08-12, review procedure, accepted residuals
2. `docs/threat-model.md`
3. `docs/security.md`
4. `docs/developer/architecture.md`
5. `docs/user/roles-and-acl.md`

## Code surfaces (deep dive — read the real code)

- `openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-luci-login.sh`
- Mutators touching login/session in `usrmanage-lib.sh` / CLI: `um_mut_del`, `um_mut_set_role`, `um_mut_passwd`, `um_mut_set_luci_login`, add-with-luci paths
- `openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage`
- `openwrt-feed/luci-app-usrmanage/root/usr/share/rpcd/acl.d/`
- LuCI view enable/disable / set_luci_login in `.../view/system/usrmanage.js`
- Proofs: `tests/test_luci_login.sh`, `scripts/qemu-smoke-usrmanage.sh` (session revoke from #95/#103)

## Do not re-file unless regression with new evidence

Closed waves: #3, #61, #63–#66, #92–#98, #95, #99–#101, #103–#104.  
Accepted residuals and #3 won’t-fix bucket in `docs/security-review.md` — leave closed unless you have new evidence.

## Product / security invariants (must preserve in findings)

- Password policy factory default OpenWrt until explicit Save.
- Passwords never on argv / audit / logs; `--password-fd` / stdin only.
- LuCI web login for managed users is opt-in; owned logins use `$p$user` only.
- Admin = full root via sudo after password (no NOPASSWD) — by design.
- `USRMANAGE_TEST_OVERRIDES=1` is test-only.
- False-green rule: `USRMANAGE_DRY_RUN=1` / host stubs are **not** proof of `lab`-class controls.

## Minimum properties to pressure-test

- Enable refuses empty / `!` / `*` shadow; never grants `*` or `luci-base` write
- Foreign / tampered never adopted; recovery fail-closed
- Disable / role / del / passwd destroy live ubus SIDs (lab-class on real ubus)
- Tx snapshot covers rpcd login for create/delete/set-role; del commit vs registry window understood
- View ACL cannot call write methods; write ACL is root-equivalent (accepted)
- Pending `uci changes rpcd` blocks enable/disable
- Passwords never argv/audit; multi-line/control rejected
- Ownership conjunction: `usrmanage=1` + `$p$user` + managed registry

## Output schema (required)

### 1. Architecture verdict

Trust boundaries, ownership conjunction, ordering invariants (revoke vs delete vs passwd validation vs tx snapshot). Cite functions/files.

### 2. Defense-in-depth gaps (ranked)

Even where the primary guard holds. Severity + why thin.

### 3. Provability matrix

For each critical property: `already_proven` | `proveable_next` | `not_proveable_here` with exact artifact or next proof step.

### 4. New findings (primary product)

Use IDs `L1`, `L2`, … Only with precise mechanism. Respect false-green rule.

**Per finding — issue-quality bar** (match waves like #63/#65/#95):

| Field | Required |
|-------|----------|
| ID + severity | Low/Med/High; exploit vs integrity vs DiD |
| Mechanism | Exact path; `file:line` and/or function names from the code you read |
| Blast radius | Who triggers; what breaks |
| Why guards fail or are thin | Primary vs missing DiD |
| Proposed fix | Concrete enough for a simpler model (which function, invariant, test) — **not** a full patch |
| Re-verify | `./scripts/smoke-host.sh`, specific test, and/or qemu-smoke assert |
| Proof class after fix | `host` / `lab` / `manual` |
| Residual? | If platform-only → proposed Accepted residual text, not a fake fix |

### 5. Explicit non-findings

Paths checked that still hold (for ledger date bump).

### 6. Issue filing plan

Group `L*` into one or few tracking issues (theme per issue, ID table). Suggested titles, dependency order for simpler-model fix PRs.

### 7. Prevention notes (short)

Only after findings: which process/CI gates would have caught these (checklist, proof-class enforcement, false-green lint). No implementation.

## Constraints

- **No code edits.**
- Do not reopen accepted residuals without new evidence.
- Prefer findings you can demonstrate with a command or a line-precise mechanism + blast radius.
- Prefer fewer high-quality findings over speculative noise.
