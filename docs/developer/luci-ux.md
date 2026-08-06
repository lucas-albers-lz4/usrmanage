# LuCI UX, themes, and i18n

Menu: **System → User Management** (`admin/system/usrmanage`).

## Layout

1. Banner: UNIX/SSH accounts; LuCI web logins are separate; admin = wheel + sudo
2. Doctor warning banner when self-check fails
3. User table: Username | UID | Role | Shell | Managed | Actions
4. Manage actions (write ACL only): Add, Set role, Password, Remove
5. Audit panel (read ACL): recent events + Refresh

View-only sessions see the table and audit; mutator controls hidden when write ACL is absent. **Server ACL is authoritative.**

## Theme expectations

- Prefer stock LuCI classes: `cbi-map`, `table`, `btn`, `cbi-button-*`, `alert-message`
- Avoid hardcoded theme-hostile colors; use theme CSS variables when custom styling is required
- Inline layout styles should be minimal and neutral
- Manual check: Bootstrap light + dark; one alternate theme if available

CI: `tests/usrmanage-theme.test.js` guards against forbidden hex in the view and requires `_()` on user-visible strings.

## Language / i18n

- All user-visible strings wrapped in `_()`
- Template: `openwrt-feed/luci-app-usrmanage/po/templates/luci-app-usrmanage.pot`
- Locale catalogs under `po/<lang>/` produce `luci-i18n-usrmanage-*` packages via `luci.mk`
- CI: `tests/usrmanage-i18n.test.js` checks POT coverage vs `_("…")` in the view

Translator workflow: update view strings → refresh POT → update `.po` → rebuild.

## ACL wiring

See [roles-and-acl](../user/roles-and-acl.md). Readonly LuCI login → read ACL only; admin → read+write.
