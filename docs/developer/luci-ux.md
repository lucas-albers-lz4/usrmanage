# LuCI UX, themes, and i18n

Menus:

- **System → Device health** (`admin/system/usrmanage-health`) — readonly owned LuCI; redacted status via `usrmanage.health`
- **System → User Management** (`admin/system/usrmanage`) — admin app scope (and full LuCI when `*` is granted)

## Device health (readonly observer)

1. Banner: LuCI login is for **device health only**, not account administration
2. Redacted fields: hostname, release, uptime, load, WAN/LAN up, Wi-Fi radio/station counts, DHCP lease count — no SSIDs, keys, MACs, or user table
3. Refresh button; errors show `health_unavailable` token only
4. View imports `view` / `rpc` / `ui` only; calls `usrmanage.health` with whole-object `expect: { '': { … } }`

## User Management layout

1. Banner: UNIX/SSH accounts; optional LuCI web login per user (`$p$`); readonly web = Device health; admin = wheel + sudo
2. Doctor banner when self-check has **errors** (expanded `alert-message error`) or **warns** only (collapsed `alert-message warning`). No green “OK” strip. Raw JSON stays under Technical details for bug reports. Wheel missing with no live managed users is a warn (created on first add); BusyBox without `stat` uses `find -perm 440` for sudoers mode.
3. Password policy strip (`Password policy: OpenWrt`) — Configure expands preset/toggles (write ACL); **Save** required; read ACL sees name only
4. User table: Username | UID | Role | Shell | Managed | LuCI | Actions
5. Manage actions (write ACL only): Add (optional LuCI checkbox; admin scope **app** vs **full** when role=admin), Set role, Password, Enable/Disable LuCI, Remove
6. Audit panel (read ACL): recent events + Refresh

View-only sessions on User Management see the table and audit; mutator controls hidden when write ACL is absent. **Server ACL is authoritative.**

## Theme expectations

- Prefer stock LuCI classes: `cbi-map`, `table`, `btn`, `cbi-button-*`, `alert-message`
- Avoid hardcoded theme-hostile colors; use theme CSS variables when custom styling is required
- Inline layout styles should be minimal and neutral
- Manual check: Bootstrap light + dark; one alternate theme if available

CI: `tests/usrmanage-theme.test.js` guards against forbidden hex in the views and requires `_()` on user-visible strings.

## Language / i18n

- All user-visible strings wrapped in `_()`
- Template: `openwrt-feed/luci-app-usrmanage/po/templates/luci-app-usrmanage.pot`
- Locale catalogs under `po/<lang>/` produce `luci-i18n-usrmanage-*` packages via `luci.mk`
- CI: `tests/usrmanage-i18n.test.js` checks POT coverage vs `_("…")` in `usrmanage.js` and `usrmanage-health.js`

Translator workflow: update view strings → refresh POT → update `.po` → rebuild.

## ACL wiring

See [roles-and-acl](../user/roles-and-acl.md). Readonly owned LuCI → health ACL only; admin app → User Management read+write; admin full → `*`.
