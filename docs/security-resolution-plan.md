# Security resolution plan — open findings (2026-08-23)

> **Status:** #158 resolved by [PR #160](https://github.com/lucas-albers-lz4/usrmanage/pull/160) (pending merge). #159 remains open in [PR #161](https://github.com/lucas-albers-lz4/usrmanage/pull/161).

Action plan for the **two open `security` issues** filed from the 2026-08-23 read-only
pass on `main@a0020ba`. Ledger: [security-review.md](security-review.md). Process locks:
[security-prevention-plan.md](security-prevention-plan.md), [AGENTS.md](../AGENTS.md).

**Scope:** security issues only. Non-security backlog (e.g. [#15](https://github.com/lucas-albers-lz4/usrmanage/issues/15) docs/screenshots) is out of scope here.

## Open work summary

| Issue | Severity | Area | Title |
|-------|----------|------|-------|
| [#159](https://github.com/lucas-albers-lz4/usrmanage/issues/159) | Low | publish / supply chain | Feed signing keys written before SDK build cells mount workspace |

**Resolved by this wave (pending merge):** [#158](https://github.com/lucas-albers-lz4/usrmanage/issues/158) — rpcd `show` write-ACL gate ([PR #160](https://github.com/lucas-albers-lz4/usrmanage/pull/160)).

**Recently closed (ledger):** #148 (SHA-512 pin), #149 (`list --all` gate), #150 (tampered login revoke).

---

## PR gate workflow (required for every security PR)

Each fix lands as its own PR. **Keep the PR in draft** until our reviews finish; only then mark **Ready for review** so CodeRabbit runs (`auto_review.drafts: false` — [developer/coderabbit.md](developer/coderabbit.md)).

```text
Branch + fix
  → open DRAFT PR (security label, "Fixes #NNN")
  → ./scripts/smoke-host.sh
  → luna review on branch changes (or grok if luna unavailable)
  → Bugbot on branch changes
  → /review-security on branch changes
  → update docs/security-review.md in the same PR
  → mark PR Ready for review
  → wait for CodeRabbit round (~5–10 min; poll pulls/<n>/reviews)
  → batch any CodeRabbit fixes in ONE push; re-run smoke + luna/grok + Bugbot + security review
  → merge when all gates green
```

### Draft vs Ready

| Phase | PR state | Who reviews |
|-------|----------|-------------|
| Implementation + our gates | **Draft** | luna or grok, Bugbot, security review |
| Our gates all clean | **Ready for review** | CodeRabbit (automatic) |
| CodeRabbit round complete, fixes batched | **Ready** (may stay ready) | Re-run our gates if head changed |
| Merge | Ready + CI green + no open findings | — |

CodeRabbit rules: one stable diff per round; do not push mid-round; rate-limit = terminal state (retry `@coderabbitai review` when quota allows).

### Same-PR ledger requirements

Per [security-prevention-plan.md](security-prevention-plan.md) and [security-review.md § Review procedure](security-review.md#review-procedure):

1. Update **Open findings** / **Resolved findings** for the tracking issue.
2. Bump **coverage map** dates for touched surfaces.
3. Append a dated **Audit history** entry with proof class and artifact paths.
4. State proof class: `host` | `lab` | `manual`.

---

## PR 1 — #158: rpcd `show` write-ACL gate

**Tracking:** [#158](https://github.com/lucas-albers-lz4/usrmanage/issues/158)  
**Suggested branch:** `fix/security-158-rpcd-show-gate`

### Problem

Read-only / diagnostic LuCI sessions hold `show` in the read ACL
(`luci-app-usrmanage.json`). The rpcd plugin calls `run_cli show "$_name" --json`
with no gate. Any valid username (including `root`, `www`, …) returns
uid/gid/home/shell/locked/luci_login — a per-name existence probe that sidesteps
the #149 write-ACL clamp on `list --all`.

### Fix (recommended: Option A)

**Option A — mirror #149 (recommended):** In
`openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage`, require
`session_has_write_acl` before honoring `show`. Read-only sessions already receive
full `um_emit_user_json` output for **managed** users via plain `list`; the LuCI
view does not call `show` today.

**Option B — managed-only for read-only:** If product needs readonly `show` for
managed users only, gate in rpcd: without write ACL, allow `show` only when the
target is in the managed registry; return `not_found` for unmanaged names (no
existence oracle on system accounts).

Pick one option in the PR description; default to **Option A** unless a readonly
`show` use case is documented.

### Files

| File | Change |
|------|--------|
| `openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage` | Add `show` gate (~line 263) |
| `tests/test_rpcd_show_acl.sh` | New — behavioral test mirroring `tests/test_rpcd_list_acl.sh` |
| `scripts/smoke-host.sh` | Wire new test |
| `docs/security-review.md` | Close #158; bump rpcd surface date; audit history |

### Proof

| Class | Artifact |
|-------|----------|
| `host` | `tests/test_rpcd_show_acl.sh` + `./scripts/smoke-host.sh` |
| `lab` | None — no new guest surface (ACL scope unchanged vs #149 pattern) |

### PR checklist (#158)

- [ ] Draft PR, `Fixes #158`, `security` label
- [ ] `./scripts/smoke-host.sh` green
- [ ] luna or grok review (branch changes)
- [ ] Bugbot (branch changes)
- [ ] `/review-security` (branch changes)
- [ ] `docs/security-review.md` updated
- [ ] Mark Ready → CodeRabbit round complete
- [ ] Merge; verify issue auto-closes

---

## PR 2 — #159: defer signing keys until after SDK build cells

**Tracking:** [#159](https://github.com/lucas-albers-lz4/usrmanage/issues/159)  
**Suggested branch:** `fix/security-159-defer-feed-keys`

### Problem

In `.github/workflows/publish-packages.yml`, **Write signing keys** (~line 107) and
**Validate signing keys** run **before** **Build packages** (~line 146). The `sdk`
compose service bind-mounts `.:/work/usrmanage:ro` while cells run as **root**, so
container root can read `opkg-secret.key` / `apk-secret.rsa` (0600) during builds.
Keys are not consumed until **Stage signed feed** / signing steps. The repo already
documents the inverse invariant for `sdk-export` (“export container must never see
them”).

### Fix

Reorder workflow steps so signing keys exist in the workspace **only after** all
`sdk` compose build cells finish:

```text
Host smoke
Restore / prepare SDK cache
Build packages (4 cells)
Verify reproducible builds (x86-64)
Fix SDK cache permissions / Save cache   (unchanged relative order)
── NEW POSITION ──
Write signing keys
Validate signing keys
Stage signed feed
… (publish steps unchanged)
```

Add a workflow comment stating the invariant: **no `feed_keys_write_from_env` before
the last `./scripts/docker-sdk.sh build` in the job.**

Do **not** mount keys outside the workspace unless a follow-up design explicitly
changes staging paths — reordering is the minimal fix aligned with existing
`feed_publish_*` env paths.

### Files

| File | Change |
|------|--------|
| `.github/workflows/publish-packages.yml` | Reorder steps; document invariant |
| `tests/test_sdk_matrix_digests.sh` (or new small test) | Grep/assert publish workflow: build steps precede `feed_keys_write_from_env` |
| `docs/security-review.md` | Close #159; update supply-chain control row; bump Release + signing / Build inputs dates |

### Proof

| Class | Artifact |
|-------|----------|
| `host` | Workflow-order grep in `tests/test_sdk_matrix_digests.sh` (or sibling) |
| `manual` | First `v*` tag publish after merge: confirm Actions job never mounts keys during build cells |

### PR checklist (#159)

- [ ] Draft PR, `Fixes #159`, `security` label
- [ ] `./scripts/smoke-host.sh` green (including new order assert)
- [ ] luna or grok review (branch changes)
- [ ] Bugbot (branch changes)
- [ ] `/review-security` (branch changes)
- [ ] `docs/security-review.md` updated (including stale #148–#150 cleanup in open table)
- [ ] Mark Ready → CodeRabbit round complete
- [ ] Merge; verify issue auto-closes
- [ ] Record manual proof on next tag publish in audit history

---

## Execution order

| Order | PR | Rationale |
|-------|-----|-----------|
| 1 | #158 ([PR #160](https://github.com/lucas-albers-lz4/usrmanage/pull/160)) | Smaller diff; completes #149 ACL theme; pure host proof |
| 2 | #159 ([PR #161](https://github.com/lucas-albers-lz4/usrmanage/pull/161)) | Workflow-only; manual proof on next release |

Both PRs touch `docs/security-review.md` — **merge #160 first**, then rebase #161 onto `main` and reconcile the ledger before marking #161 ready.

---

## Out of scope

- [#15](https://github.com/lucas-albers-lz4/usrmanage/issues/15) — documentation / Playwright WebP gallery
- Accepted residuals (I3 TOCTOU, ubus password hop, diagnostic `uci get`, etc.) — see [security-review.md § Accepted residuals](security-review.md#accepted-residuals)
- Re-opening closed #148–#150 — ledger cleanup only

---

## Success criteria

- Open `security` issue count returns to **zero** (#158 and #159 closed).
- `docs/security-review.md` open findings table empty; #148–#150 only in resolved/history.
- Every merged PR has: host smoke green, luna/grok + Bugbot + security review on head, CodeRabbit round completed before merge declaration.
- #159: next tag publish confirms keys were not on disk during SDK build cells (manual audit history note).

## Related

- [security-review.md](security-review.md) — ledger and review procedure
- [security-prevention-plan.md](security-prevention-plan.md) — PR checklist and proof classes
- [developer/coderabbit.md](developer/coderabbit.md) — draft/ready protocol
- [AGENTS.md](../AGENTS.md) — product locks and merge gates
