# Roles and LuCI ACL

## Device roles (UNIX)

| Role | Meaning |
|------|---------|
| **readonly** | SSH/shell user, not in `wheel`, no sudo |
| **admin** | Member of `wheel`; `sudo` to root after password (full root by design) |

Readonly on the web is **diagnostic** scope: look, don’t touch configuration, don’t get Full LuCI. The same UNIX password still allows SSH (documented residual — the LuCI guarantee is web/ubus only).

## App access (this package)

| Tier | ubus methods | Who |
|------|--------------|-----|
| **health** | `health` | readonly diagnostic (`luci-app-usrmanage-health`) |
| **view** | `list`, `show`, `audit`, `doctor`, `policy` | diagnostic read + SSH / Full LuCI |
| **manage** | `add`, `del`, `set_role`, `passwd`, `set_luci_login`, `get_policy`, `set_policy` | Full LuCI (`*`) / SSH admin / root CLI |

**Write ACL is root-equivalent:** a web session with `luci-app-usrmanage` write (or `*`) can create admins and change passwords (same blast radius as SSH admin + sudo).

## Opt-in LuCI login (managed accounts)

Default remains **SSH-only**. Operators may enable LuCI per managed user (Add checkbox, table Enable/Disable, or `usrmanage set-luci-login <user> --enable`).

Owned logins always use **`$p$username`**. ACL matrix is **fixed by UNIX role** (no `--scope` picker):

| UNIX role | Web scope | rpcd grants |
|-----------|-----------|-------------|
| readonly | **diagnostic** | `read`: session, health, `luci-app-usrmanage` (view methods), `luci-app-usrmanage-diagnostic-rpc` (page RPCs), `luci-mod-status-index`, `luci-mod-status-routes`, `luci-mod-status-realtime`, `luci-mod-network-config`, `luci-mod-network-diagnostics`. **Empty write list** (stock group write blocks stay denied). |
| admin | **full** | `read`: `*`; `write`: `*` |

Legacy `usrmanage_scope 'app'` normalizes to **diagnostic** and is rewritten on sync/upgrade. Enabling LuCI for admin grants Full LuCI by design.

`luci-app-usrmanage-session` is a narrow shell ACL (session + features only — no UCI read). Diagnostic stock groups are granted on **read only** so Interfaces/Overview stay non-mutating. Hand-tuned `luci-app-acl` logins remain untouched; usrmanage refuses to enable when a foreign login already claims the username.

**Menus:** readonly owned → Status (Overview, Routing, Realtime), Network (Interfaces, Diagnostics), Device health, User Management **view-only**. Admin owned → full stock LuCI including User Management mutators.

Package upgrade rewrites owned logins to the role-locked matrices (readonly→diagnostic, admin→full) and revokes sessions whose ACLs changed.

States in `list`/`show`: `luci_login` = `none` | `owned` | `foreign` | `tampered`.

## Manual wiring (still supported)

Use **System → Administration** / `luci-app-acl` for custom principals (including separate hash passwords). Do not mix a foreign login and an owned login for the same username.

## Password policy

Factory default is the **OpenWrt** preset (minimum 8 characters; password must not equal the username). Stricter presets (**Standard**, **Strict**) and individual toggles apply only after an operator opens **Configure** on User Management and clicks **Save**.

Read-only LuCI sessions on User Management see the policy **name** only and cannot run mutators. Write sessions (Full LuCI / SSH admin) see the full editor and a live checklist in Add / Change password dialogs.
