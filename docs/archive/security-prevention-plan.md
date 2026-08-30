# Security prevention plan — usrmanage

Second-priority follow-on from the 2026-08-12 LuCI-login deep dive.
Audit results: [security-audit-luci-login-2026-08-12.md](security-audit-luci-login-2026-08-12.md).
Ledger: [security-review.md](../security-review.md).

**Goal:** stop another find→fix wave by making proof and DiD requirements enforceable on PRs — not more prose alone.

Remediation of [#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105)–[#107](https://github.com/lucas-albers-lz4/usrmanage/issues/107) should be implemented by simpler models; run Cursor **`/review-security`** on those PRs (diff-scoped skill — correct use).

## PR checklist (auth / session / password / rpcd / ACL / signing)

Add to the PR template (or require in review) when touching these surfaces:

1. **Control row** updated or added under Controls in force in `docs/security-review.md`.
2. **Proof class** stated: `host` | `lab` | `manual`.
3. **Proof artifact** named (test path, qemu-smoke assert, or dated manual note) — **or** an open `security` issue that **blocks release acceptance**.
4. Coverage map **dates** bumped for touched surfaces in the same PR.
5. If the change syncs or rewrites LuCI/rpcd ACLs: document whether **live sessions are revoked** (including same-role / repair paths).
6. Never cite `USRMANAGE_DRY_RUN=1` host stubs as proof of a `lab`-class control.

## Three rules the 2026-08-12 pass added

These come from findings that the existing gates could not have caught. They generalize past the specific bugs.

1. **A control that names a file mode needs a mode assertion.** L5 shipped because no test
   ever ran `stat` on a file usrmanage rewrites — "umask 077 temp → fixed mode → mv" was
   documented prose, not a checked property. Any control row asserting permissions,
   ownership, or atomicity must cite a test that asserts it.
2. **Fix the class, not the site.** [#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63)
   R2 was the exact same temp-file-mode defect, fixed only in the release pipeline. The
   identical bug sat in the on-device path for months. When a finding is a *class*, the
   remediation PR must include a repo-wide sweep for the pattern and the ledger entry must
   record what was swept.
3. **Never hand-parse a platform format in a security decision.** L4 exists because
   ownership is decided by an awk grammar narrower than libuci's. Use the platform tool
   (`uci`, `getent`), or fail closed on any input the parser cannot fully model. Silently
   returning `none` for an unparsed file turns a revocation control into a no-op.

## Concrete prevention PRs (suggested)

| Order | Work | Addresses |
|-------|------|-----------|
| 1 | Fix L5 + L6 ([#109](https://github.com/lucas-albers-lz4/usrmanage/issues/109)) with **mode-assertion** host tests; sweep every `chmod`/redirect-then-`mv` site in the repo | Active on-device exposure + rule 1/2 |
| 2 | Fix L4 ([#108](https://github.com/lucas-albers-lz4/usrmanage/issues/108)) via `uci` enumeration or fail-closed validator + one host test per syntax form | Revocation correctness + rule 3 |
| 3 | Fix L2 ([#106](https://github.com/lucas-albers-lz4/usrmanage/issues/106)) tx or single-pass rewrite + host test | Crash window |
| 4 | Fix L3 then L1 ([#105](https://github.com/lucas-albers-lz4/usrmanage/issues/105)) with host tests | Product gaps |
| 5 | Lab asserts ([#107](https://github.com/lucas-albers-lz4/usrmanage/issues/107)) in `qemu-smoke-usrmanage.sh` — after #108 | False-green / proveable_next |
| 6 | PR template section (checklist above) + short pointer from `AGENTS.md` / review procedure | Process |
| 7 | Host lint: if `docs/security-review.md` lists `lab` proof for a control, require the cited script path to exist and not be only a DRY_RUN stub | Automation |

Run `/review-security` on each of these PRs — that is the diff-scoped tool's correct use.

## What not to do

- Do not re-open Accepted residuals or the #3 won’t-fix bucket without new evidence.
- Do not use `/review-security` for full-repo architecture audits (diff-only).
- Do not merge LuCI/session features with unchecked lab boxes and no release-blocking issue.

## Success

- Open findings #105–#107 closed with matching proof class.
- Next feature that adds a mutator/session write cannot merge without a control row + proof (human checklist first; lint if ROI is clear).
