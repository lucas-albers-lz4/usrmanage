# LuCI UX, themes, and i18n

Menus:

- **System → Device health** (`admin/system/usrmanage-health`) — redacted status via `usrmanage.health`; included in the readonly diagnostic profile
- **System → User Management** (`admin/system/usrmanage`) — view-only for readonly diagnostic logins; admin logins receive Full LuCI

## Device health (readonly diagnostic profile)

1. Banner: LuCI login is for **device health only**, not account administration
2. Redacted fields: hostname, release, uptime, load, WAN/LAN up, Wi-Fi radio/station counts, DHCP lease count — no SSIDs, keys, MACs, or user table
3. Refresh button; errors show `health_unavailable` token only
4. View imports `view` / `rpc` / `ui` only; calls `usrmanage.health` with whole-object `expect: { '': { … } }`
5. **Log out** uses stock `admin/logout`. A later `menu.d` override sets `depends.acl` to `luci-app-usrmanage-session` only (LuCI treats the ACL list as **AND**, not OR). Readonly observers already have that group; `*` logins get it via rpcd expanding every installed ACL group. Do not list `luci-base` alongside it — that would hide logout for observers.

## User Management layout

1. Banner: UNIX/SSH accounts; optional LuCI web login per user (`$p$`); readonly LuCI = diagnostic menus plus view-only User Management; admin = Full LuCI (wheel + sudo)
2. Doctor banner when self-check has **errors** (expanded `alert-message error`) or **warns** only (collapsed `alert-message warning`). No green “OK” strip. Raw JSON stays under Technical details for bug reports. Wheel missing with no live managed users is a warn (created on first add); BusyBox without `stat` uses `find -perm 440` for sudoers mode.
3. Password policy strip (`Password policy: OpenWrt`) — Configure expands preset/toggles (write ACL); **Save** required; read ACL sees name only. Add/Change password modals use a **quieter** live checklist (circular ✓/✗ via theme `--success-color-*` / `--error-color-*`; see `usrmanage.css`).
4. User table: Username | UID | Role | Shell | Managed | LuCI | Actions
5. Manage actions (write ACL only): Add (optional LuCI checkbox; role fixes scope: readonly = diagnostic, admin = Full), Set role, Password, Enable/Disable LuCI, Remove. There is no scope picker.
6. Audit panel (read ACL): recent events + Refresh

View-only sessions on User Management see the table and audit; mutator controls hidden when write ACL is absent. **Server ACL is authoritative.**

## Theme expectations

- Prefer stock LuCI classes: `cbi-map`, `table`, `btn`, `cbi-button-*`, `alert-message`
- Avoid hardcoded theme-hostile colors; use theme CSS variables when custom styling is required
- Inline layout styles should be minimal and neutral
- Manual check: Bootstrap light + dark; one alternate theme if available

CI: `tests/usrmanage-theme.test.js` checks forbidden hex colors, JavaScript syntax, and selected theme-friendly classes. It does **not** enforce `_()` on all user-visible strings. `tests/usrmanage-i18n.test.js` checks POT coverage for strings already wrapped in `_()`; it is not an unwrapped-string scanner.

## Language / i18n

- All user-visible strings wrapped in `_()`
- Template: `openwrt-feed/luci-app-usrmanage/po/templates/luci-app-usrmanage.pot`
- Locale catalogs under `po/<lang>/` produce `luci-i18n-usrmanage-*` packages via `luci.mk`
- CI: `tests/usrmanage-i18n.test.js` checks POT coverage vs `_("…")` in `usrmanage.js` and `usrmanage-health.js`

Translator workflow: update view strings → refresh POT → update `.po` → rebuild.

## ACL wiring

See [roles-and-acl](../user/roles-and-acl.md). Readonly owned LuCI → diagnostic profile (Status/Network diagnostics, Device health, and view-only User Management); admin owned LuCI → Full (`*`). Scope is role-locked; there is no app/full picker.
