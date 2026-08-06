# Roles and LuCI ACL

## Device roles (UNIX)

| Role | Meaning |
|------|---------|
| **readonly** | SSH/shell user, not in `wheel`, no sudo |
| **admin** | Member of `wheel`; `sudo` to root after password (full root by design) |

## App access (this package)

| Tier | ubus methods | Who |
|------|--------------|-----|
| **view** | `list`, `show`, `audit`, `doctor` | readonly operators / read ACL |
| **manage** | `add`, `del`, `set_role`, `passwd` | admins / write ACL / root CLI |

## LuCI login wiring (v1)

Usrmanage does **not** auto-create LuCI logins. Use **System → Administration** / `luci-app-acl`:

1. Create rpcd login with password variant **Use UNIX password** (`$p$username`).
2. Grant ACL group `luci-app-usrmanage`:
   - Readonly web user → **read** only
   - Admin web user → **read + write**

## Password policy

Factory default is the **OpenWrt** preset (minimum 8 characters; password must not equal the username). Stricter presets (**Standard**, **Strict**) and individual toggles apply only after an operator opens **Configure** on User Management and clicks **Save**.

Read-only LuCI sessions see the policy **name** only. Write sessions see the full editor and a live checklist in Add / Change password dialogs.
