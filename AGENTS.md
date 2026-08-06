# usrmanage — agent notes

OpenWrt **local UNIX user management** (CLI + LuCI): managed users, readonly vs admin (`wheel`+sudo), operational audit, password policy presets.

## Product locks (do not casually change)

- Supported releases: **23.05 / 24.10 / 25.12** only (`PKGARCH:=all`).
- Password policy factory default: **OpenWrt** (min 8, reject username). Stricter presets/toggles apply only after explicit LuCI **Save** (or CLI `set-policy`).
- Read ACL: policy **name/label only**. Write ACL: `get_policy` / `set_policy` + mutators.
- Passwords: never on argv or in audit/logs; LuCI → rpcd → `--password-fd` / stdin only.
- LuCI web logins are **not** auto-created; wire via `luci-app-acl` (`$p$user`).
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
- Known review backlog: GitHub issue **#3** (Zen MCR). Do not “clean up” pipeline-unrelated labeled work elsewhere without asking.

## Workflows

- Host checks: `./scripts/smoke-host.sh`
- QEMU (x86): prepare image → `validate-feed-smoke.sh` / stepwise scripts under `scripts/qemu-*.sh`
- Feed: https://lucas-albers-lz4.github.io/usrmanage-packages/ — tag `v*` publishes
- Prefer **one issue + one PR** for a feature; run Bugbot before merge when requested
- Do not commit secrets (`*.key`, feed signing material). `lab/` images are gitignored

## Layout

| Path | Role |
|------|------|
| `openwrt-feed/usrmanage/` | CLI, lib, UCI, sudoers |
| `openwrt-feed/luci-app-usrmanage/` | LuCI view, rpcd, ACL, po |
| `docs/` | Architecture, security, user/install |
| `scripts/` | Host smoke, SDK, publish, QEMU lab |
| `tests/` | Validators, theme, i18n |
