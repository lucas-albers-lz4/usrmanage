# usrmanage — agent notes

OpenWrt **local UNIX user management** (CLI + LuCI): managed users, readonly vs admin (`wheel`+sudo), operational audit, password policy presets.

## Product locks (do not casually change)

- Supported releases: **24.10 / 25.12** only (`PKGARCH:=all`). OpenWrt 23.05 users stay on v0.1.2.
- Password policy factory default: **OpenWrt** (min 8, reject username). Stricter presets/toggles apply only after explicit LuCI **Save** (or CLI `set-policy`).
- Read ACL: policy **name/label only**. Write ACL: `get_policy` / `set_policy` + mutators.
- Passwords: never on argv or in audit/logs; LuCI → rpcd → `--password-fd` / stdin only.
- LuCI web logins for managed users are **opt-in** (`set-luci-login` / Add checkbox); owned logins use `$p$user` only. Manual `luci-app-acl` still supported for foreign principals.
- Admin = full root via sudo after password (no NOPASSWD) — by design.

## Code conventions

- Shell: BusyBox ash-safe (`usrmanage-lib.sh`). Prefer quoted args; never unquoted `$*` into privileged CLI.
- LuCI `rpc.declare` expect: use `{ '': { ... } }` to keep the **whole** reply object. Drilling (`expect: { ok: false }`) returns a bare field and breaks the UI.
- Nested DOM: pass a single node or `null` into `E()` children — not a nested array (stringifies to `[object HTMLDivElement]`).
- Theme: stock LuCI classes only; no hardcoded hex in the view (see `tests/usrmanage-theme.test.js`).
- i18n: wrap user-visible strings in `_()`; keep POT/`po/de` in sync (`tests/usrmanage-i18n.test.js`).

## Security (must preserve)

- Sanitize audit `actor` / `src` (no spaces, `=`, or field injection).
- rpcd: call CLI with explicit quoted argv per method; require `jsonfilter` (no sed JSON for passwords).
- Prefer `flock` for the op lock; do not leave stale locks on `um_die`.
- Audit denials (`denied`) on mutator validation failures, not only successes.
- Known review backlog: GitHub issue **#3**. Do not “clean up” pipeline-unrelated labeled work elsewhere without asking.

## Testing

Details: [docs/developer/testing.md](docs/developer/testing.md).

- **PR CI / done gate:** `./scripts/smoke-host.sh` (shellcheck, layout, validators, mutators, theme, i18n). Host-only — no QEMU/Playwright in PR CI.
- **QEMU lab:** SSH `127.0.0.1:2222`, LuCI `http://127.0.0.1:8080`, root empty password on prepared images. CLI/ubus smoke: `scripts/qemu-smoke-usrmanage.sh`. Fixture users (`umadmin`, `pwflow_*`) are **lab-only**, not product defaults.
- **Playwright MCP:** `.cursor/mcp.json` — enable in Cursor Settings → MCP; use for interactive LuCI exploration when the guest is up. Never put passwords in MCP traces/logs.
- **E2E:** `./scripts/playwright-luci.sh` (`tests/e2e/`) against a running lab; EN UI; unique usernames + SSH cleanup.
- **Docs screenshots:** planned (#15) — WebP via Playwright; clean managed-user list (no stray smoke/e2e accounts) before capture.

## Release / feed

Details: [docs/release.md](docs/release.md), [docs/binary-feed.md](docs/binary-feed.md).

- Version: bump **third octet** of `PKG_VERSION` in both Makefiles; keep `PKG_RELEASE:=1`; tag `v0.1.N` (not `v0.1.0-r2`).
- Tag `v*` → `publish-packages` (6-cell SDK matrix → signed feed on Pages). Do not cut a release until lab acceptance when asked.
- Feed: https://lucas-albers-lz4.github.io/usrmanage-packages/
- Never commit secrets (`*.key`, feed signing material). `lab/` images are gitignored.

## Workflows

- Prefer **one issue + one PR**; run automated review before merge when requested.
- QEMU stepwise: `scripts/qemu-*.sh` / `validate-feed-smoke.sh`.

## Layout

| Path | Role |
|------|------|
| `openwrt-feed/usrmanage/` | CLI, lib, UCI, sudoers |
| `openwrt-feed/luci-app-usrmanage/` | LuCI view, rpcd, ACL, po |
| `docs/` | Architecture, security, user/install, testing, release |
| `scripts/` | Host smoke, SDK, publish, QEMU lab, Playwright runner |
| `tests/` | Validators, mutators, theme, i18n |
| `tests/e2e/` | Playwright LuCI flows (QEMU lab) |
| `.cursor/mcp.json` | Playwright MCP for agents |
