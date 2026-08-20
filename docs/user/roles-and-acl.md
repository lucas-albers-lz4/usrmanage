# Roles and LuCI ACL

## Device roles (UNIX)

| Role | Meaning |
|------|---------|
| **readonly** | SSH/shell user, not in `wheel`, no sudo |
| **admin** | Member of `wheel`; `sudo` to root after password (full root by design) |

Readonly **is** the observer profile on the web: look, don’t touch, don’t see secrets over LuCI/ubus. The same UNIX password still allows SSH (documented residual — the LuCI guarantee is web/ubus only).

## App access (this package)

| Tier | CLI/ubus operations | Who |
|------|---------------------|-----|
| **health** | `health` | readonly owned LuCI (`luci-app-usrmanage-health`) |
| **view** | `list`, `show`, `audit`, `doctor`, `policy` | readonly SSH CLI (view-only) · admin app read ACL over ubus |
| **manage** | `add`, `del`, `set_role`, `passwd`, `set_luci_login`, `get_policy`, `set_policy` | admins / write ACL / root CLI |

**Write ACL is root-equivalent:** a web session with `luci-app-usrmanage` write can create admins and change passwords (same blast radius as SSH admin + sudo).

## Opt-in LuCI login (managed accounts)

Default remains **SSH-only**. Operators may enable LuCI per managed user (Add checkbox, table Enable/Disable, or `usrmanage set-luci-login <user> --enable`).

Owned logins always use **`$p$username`** (same UNIX password — no separate web password for accounts usrmanage manages). ACL matrix is fixed by role and admin web scope:

| UNIX role | Web scope | rpcd grants |
|-----------|-----------|-------------|
| readonly | *(n/a — health only)* | `read`: `luci-app-usrmanage-session`, `luci-app-usrmanage-health` |
| admin | **app** (default) | `read`: session + `luci-app-usrmanage`; `write`: `luci-app-usrmanage` |
| admin | **full** (`--scope full`) | `read`: `*`; `write`: `*` |

`luci-app-usrmanage-session` is a narrow shell ACL (session + features only — no UCI read). `luci-app-usrmanage-health` exposes **`health` only** (redacted device status; no user table, keys, or backups). Hand-tuned `luci-app-acl` logins remain untouched; usrmanage refuses to enable when a foreign login already claims the username.

**Menus:** readonly owned → **System → Device health** only. Admin **app** → User Management only. Admin **full** → full stock LuCI plus User Management.

Package upgrade rewrites readonly owned logins to session+health and **never** auto-widens admin to `*`. Full LuCI requires explicit `--scope full` (or the admin scope control in Add / Enable LuCI).

States in `list`/`show`: `luci_login` = `none` | `owned` | `foreign` | `tampered`.

## Manual wiring (still supported)

Use **System → Administration** / `luci-app-acl` for custom principals (including separate hash passwords). Do not mix a foreign login and an owned login for the same username.

## Password policy

Factory default is the **OpenWrt** preset (minimum 8 characters; password must not equal the username). Stricter presets (**Standard**, **Strict**) and individual toggles apply only after an operator opens **Configure** on User Management and clicks **Save**.

Read-only LuCI sessions on User Management see the policy **name** only. Write sessions see the full editor and a live checklist in Add / Change password dialogs. Readonly observer sessions do not receive User Management at all.
