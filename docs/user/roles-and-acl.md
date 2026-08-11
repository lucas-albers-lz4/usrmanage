# Roles and LuCI ACL

## Device roles (UNIX)

| Role | Meaning |
|------|---------|
| **readonly** | SSH/shell user, not in `wheel`, no sudo |
| **admin** | Member of `wheel`; `sudo` to root after password (full root by design) |

## App access (this package)

| Tier | ubus methods | Who |
|------|--------------|-----|
| **view** | `list`, `show`, `audit`, `doctor`, `policy` | readonly operators / read ACL |
| **manage** | `add`, `del`, `set_role`, `passwd`, `set_luci_login`, `get_policy`, `set_policy` | admins / write ACL / root CLI |

**Write ACL is root-equivalent:** a web session with `luci-app-usrmanage` write can create admins and change passwords (same blast radius as SSH admin + sudo).

## Opt-in LuCI login (managed accounts)

Default remains **SSH-only**. Operators may enable LuCI per managed user (Add checkbox, table Enable/Disable, or `usrmanage set-luci-login <user> --enable`).

Owned logins always use **`$p$username`** (same UNIX password — no separate web password for accounts usrmanage manages). ACL matrix is fixed by role:

| UNIX role | rpcd grants |
|-----------|-------------|
| readonly | `read`: `luci-app-usrmanage-session`, `luci-app-usrmanage` |
| admin | same `read` + `write`: `luci-app-usrmanage` |

`luci-app-usrmanage-session` is a narrow shell ACL (not full `luci-base` filesystem listing). Hand-tuned `luci-app-acl` logins remain untouched; usrmanage refuses to enable when a foreign login already claims the username.

States in `list`/`show`: `luci_login` = `none` | `owned` | `foreign` | `tampered`.

## Manual wiring (still supported)

Use **System → Administration** / `luci-app-acl` for custom principals (including separate hash passwords). Do not mix a foreign login and an owned login for the same username.

## Password policy

Factory default is the **OpenWrt** preset (minimum 8 characters; password must not equal the username). Stricter presets (**Standard**, **Strict**) and individual toggles apply only after an operator opens **Configure** on User Management and clicks **Save**.

Read-only LuCI sessions see the policy **name** only. Write sessions see the full editor and a live checklist in Add / Change password dialogs.
