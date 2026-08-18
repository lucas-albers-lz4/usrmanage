# usrmanage — agent notes

OpenWrt local UNIX user management (CLI + LuCI). Product locks and LuCI traps
below; testing/release details stay in the linked docs.

## Product locks (do not casually change)

- Supported releases: **24.10 / 25.12** only (`PKGARCH:=all`). OpenWrt 23.05 users stay on v0.1.2.
- Password policy factory default: **OpenWrt** (min 8, reject username). Stricter presets/toggles only after explicit LuCI **Save** (or CLI `set-policy`).
- Read ACL: policy **name/label only**. Write ACL: `get_policy` / `set_policy` + mutators.
- Passwords: never on argv or in audit/logs; LuCI → rpcd → `--password-fd` / stdin only.
- LuCI web logins for managed users are **opt-in** (`set-luci-login` / Add checkbox); owned logins use `$p$user` only. Manual `luci-app-acl` still supported for foreign principals.
- Admin = full root via sudo after password (no NOPASSWD) — by design.

## Code conventions

- Shell: BusyBox ash-safe (`usrmanage-lib.sh`). Prefer quoted args; never unquoted `$*` into privileged CLI.
- LuCI `rpc.declare` expect: use `{ '': { ... } }` to keep the **whole** reply object. Drilling (`expect: { ok: false }`) returns a bare field and breaks the UI.
- Nested DOM: pass a single node or `null` into `E()` children — not a nested array.
- Theme: stock LuCI classes only; no hardcoded hex (`tests/usrmanage-theme.test.js`).
- i18n: wrap user-visible strings in `_()`; keep POT/`po/de` in sync.

## Security (must preserve)

- Sanitize audit `actor` / `src` (no spaces, `=`, or field injection).
- rpcd: explicit quoted argv; require `jsonfilter` (no sed JSON for passwords).
- Prefer `flock` for the op lock; do not leave stale locks on `um_die`.
- Audit denials (`denied`) on mutator validation failures, not only successes.
- Release path: no `${{ }}` into workflow `run:` bodies, no unpinned tools executed at release, signing keys mode 0600.
- Review SoT: [docs/security-review.md](docs/security-review.md) (proof class `host` | `lab` | `manual`). Do not reopen accepted residuals / #3 won't-fix without new evidence. Feature PRs that touch auth/session/password/rpcd/ACL/signing update the ledger in the same PR; `lab`-class locks need qemu-smoke or a release-blocking issue (DRY_RUN/host stubs are not proof). Findings: `security` label + IDs (`S1`, `R1`, `P1`).

## Testing

PR / done gate: `./scripts/smoke-host.sh` (needs `flock` locally). Host-only — no QEMU/Playwright in PR CI.

Lab and Playwright: [docs/developer/testing.md](docs/developer/testing.md). Never put passwords in MCP traces.

## Release / feed

Bump **third octet** of `PKG_VERSION` in both Makefiles (+ `APP_VERSION` mirror in the view); `PKG_RELEASE:=1`; tag `v0.1.N`. Never commit secrets. Details: [docs/release.md](docs/release.md), [docs/binary-feed.md](docs/binary-feed.md).
