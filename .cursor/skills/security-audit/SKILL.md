---
name: security-audit
description: Audit the usrmanage repository for security issues — CLI/password paths, rpcd+ACL, LuCI view, and the signing/release pipeline. Use when the user asks for a security audit, security review, threat model, or hardening pass on this repo.
---

# usrmanage security audit

Repeatable audit procedure. Read
[`docs/threat-model.md`](../../../docs/threat-model.md) and
[`docs/security.md`](../../../docs/security.md) for trust boundaries, and
[`docs/security-review.md`](../../../docs/security-review.md) for what has
already been checked, with what proof, and what is open. This file is the *how*.

A pass owes the ledger a coverage-map update, a proof class for every control it
touches, and its non-findings — see
[security-review.md § Review procedure](../../../docs/security-review.md#review-procedure).

## Multi-model pass (VVAH-style)

Token-efficient asymmetric loop shared with sibling OpenWrt packages (e.g.
fwlive). Cheap/deterministic work first; reserve a **frontier reasoner** only
for narrow judgment. Do not invent a new procedure in chat — follow this
section.

### Phase order

1. **Close open issues / prove honest gaps** (ledger `Next step` / lab locks)
   before a broad re-read.
2. **Delta** since the last coverage-map dates (touched surfaces only).
3. **Full-pass gate** — only if criteria below fire; otherwise record deferral.

### Frontier reasoner profiles

Pick **one** Stage-2 reasoner for the pass. Do not mix both in the same packet
round.

| Profile | Stage 2 (reason) | Stage 1 helpers | Validation panel | Notes |
|---------|------------------|-----------------|------------------|-------|
| **Fable** (default when available) | Claude Fable 5.1 — medium effort; high only for root/password/ACL chains | Grok (map) + Luna (polish) | Luna + Grok (severity) | Strong on multi-step auth/ACL chains |
| **GLM** (alternate review process) | GLM-5.3 at **max thinking** | Luna + GLM-5.3 Flash **or** DeepSeek V4 Flash | Luna + the same flash helper (severity) | Use when the orchestrator runs GLM instead of Fable; max thinking is required |

Composer remains Stage 3 (patches) under both profiles. Doc-only PRs do not
need a frontier reasoner — Luna (+ optional Grok for cross-repo wording) is
enough.

### Stages and models

| Stage | Job | Model (see profile above) | Token rule |
|-------|-----|---------------------------|------------|
| 0 Static seed | Repo greps, `./scripts/smoke-host.sh`, key `git check-ignore`, action SHA pin spot-check, CodeQL dismissed alerts | Deterministic | Zero LLM |
| 1 Prep & triage | Job packets from ledger + diff | Profile helpers | Cheap |
| 2 Audit & reason | Multi-step chains; Engineer Mode; fix sketch beside each finding | Profile frontier reasoner | Premium, narrow |
| 3 Execute & fix | Patches, tests, ledger | Composer | Bulk output |
| Validation panel | Mechanism real? severity calibrated? duplicate of accepted residual / #3 won't-fix? | Profile validation pair | Cheap gate before filing |

**Maker-never-grader:** The Stage-2 reasoner must not bulk-write patches.
Composer must not invent new trust boundaries (edit the threat model only when
a finding falsifies it). Validation-panel models score candidates before filing.

**Engineer Mode (Stage-2 stub):** You are reviewing production code for
structural security flaws. For each finding: mechanism, location, blast radius,
severity per this repo's calibration, and a concrete fix sketch. Do not
role-play an attacker sandbox or request exploit payloads. Scope is exactly the
attached job packet checklist — not "find any security issue."

**Static cache block (identical on every Stage-2 call):** threat-model summary +
product locks from [`AGENTS.md`](../../../AGENTS.md) + severity / false-green
rules from the ledger.

### Job-packet template

Ephemeral (chat or scratch dir — do not commit noise):

- Files / short diff summary
- Cached threat-model block (above)
- Checklist (surface-specific)
- Prior non-findings for that surface from the ledger
- Expected proof class on exit (`host` / `lab` / `manual`)

### Full-pass gate

Run a full surface re-pass only if one of:

- A gap failed and suggests a **class** bug (fix-the-class sweep)
- Delta Stage-2 reasoner finds high/medium with blast radius beyond touched files
- A root-reachable control is still only `manual` with no raise path
- Pre-`v*` tag and pin checklist is stale

Otherwise update coverage-map dates for surfaces examined, record non-findings,
and set ledger `Next step` to the deferral reason.

### Cross-repo class memory (Stage 0 checklist)

Not a Stage-2 dump — grep/confirm mechanically:

- Temp mode loss after `mv` / normalize rewrite
- Unswept pin neighbors (one helper pinned, sibling not)
- Hand-parsed platform formats narrower than `uci` / platform tools
- R7: digest-pin before secret mount + `--network none` on signing containers
- Workflow `${{ }}` interpolated into `run:` bodies
- Secrets written into the workspace while an SDK/build container can read them

### usrmanage bindings

| Binding | Value |
|---------|-------|
| Threat model | [`docs/threat-model.md`](../../../docs/threat-model.md), [`docs/security.md`](../../../docs/security.md) |
| Ledger | [`docs/security-review.md`](../../../docs/security-review.md) |
| Host gate | `./scripts/smoke-host.sh` |
| Lab gate | `./scripts/qemu-smoke-usrmanage.sh` |
| Highest-yield surface | CLI + password / lockout + rpcd mutators |
| Honest gaps / Next | Ledger header `Next step` (dated QEMU lab: readonly diagnostic/full + session revoke) |

## Order of work

Prefer the multi-model phase order above. For a full surface pass, walk the
coverage map oldest-first (ledger rule).

```
- [ ] 0. Multi-model: open issues / honest gaps → delta → gate
- [ ] 1. CLI + shared library (validators, password path, lock)
- [ ] 2. rpcd plugin + ACL scope
- [ ] 3. LuCI view (E() / expect convention)
- [ ] 4. On-device install surface (sudoers, uci-defaults, diagnostic RPC)
- [ ] 5. Release pipeline (secrets, pinning, SDK mount timing)
```

## Stage 0 — mechanical checks

```sh
./scripts/smoke-host.sh
rg -n '\$\{\{|uses:' .github/workflows
rg -n 'eval|chpasswd|password|--password' openwrt-feed/usrmanage openwrt-feed/luci-app-usrmanage
git check-ignore -v opkg-secret.key apk-secret.rsa public.key '*.tmp' 2>/dev/null || true
gh api repos/:owner/:repo/code-scanning/alerts --jq '.[] | select(.state!="open") | "\(.number) \(.state) \(.rule.id)"' | head
```

## Severity calibration

| Severity | Bar |
|----------|-----|
| High | Unauthenticated or unprivileged-local attacker reaches root, password material, or last-admin lockout |
| Medium | Requires a shared host, maintainer mistake, or narrow race |
| Low | Requires an authenticated session already holding the relevant ACL, or write access to the repo |

## Reporting

[`SECURITY.md`](../../../SECURITY.md): exploitable vulnerabilities → private
disclosure / draft advisory — never a public issue with payloads. Hardening →
public issue with `security` label and an ID (`S1`, `R1`, `P1`) linked from the
ledger.

## Known-good — do not re-litigate without new evidence

Do not reopen the #3 won't-fix bucket or
[Accepted residuals](../../../docs/security-review.md#accepted-residuals)
without new evidence. Apply the ledger **false-green rule**: DRY_RUN / stub
skips are not proof of `lab`-class controls.
