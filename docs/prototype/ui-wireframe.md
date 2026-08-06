# Usrmanage LuCI UI wireframe (prototype)

Menu: **System → User Management**  
ACL: read (view) vs write (manage). View-only sessions see the page without mutator controls.

## Layout

```
┌─────────────────────────────────────────────────────────────┐
│ User Management                                             │
│ UNIX/SSH accounts on this device. LuCI web logins are       │
│ configured separately (System → Administration / ACL).      │
│ Admin role = wheel + sudo (full root).                      │
├─────────────────────────────────────────────────────────────┤
│ [doctor banner if fail-closed / missing sudo / etc.]        │
├─────────────────────────────────────────────────────────────┤
│ Users                              [ Add user ] (manage)    │
│ ┌──────────┬─────┬──────────┬──────────┬─────────┬────────┐ │
│ │ Username │ UID │ Role     │ Shell    │ Managed │ Actions│ │
│ ├──────────┼─────┼──────────┼──────────┼─────────┼────────┤ │
│ │ audit    │1001 │ readonly │ /bin/ash │ yes     │  —     │ │
│ │ ops      │1002 │ admin    │ /bin/ash │ yes     │ Role ▾ │ │
│ │          │     │          │          │         │ Passwd │ │
│ │          │     │          │          │         │ Remove │ │
│ └──────────┴─────┴──────────┴──────────┴─────────┴────────┘ │
│ ☐ Show unmanaged accounts (--all)                           │
├─────────────────────────────────────────────────────────────┤
│ Audit log                                      [ Refresh ]  │
│ 2026-08-05T23:16:10Z grant user=audit role=readonly …       │
│ 2026-08-05T23:41:12Z remove user=audit …                    │
└─────────────────────────────────────────────────────────────┘
```

## Modals (manage ACL only)

### Add user
- Username (strict charset)
- Role: readonly | admin
- Password + confirm (min length 8, ≠ username)

### Set role
- Select readonly | admin
- Block demoting last managed admin

### Change password
- Password + confirm (same policy)
- Sent to backend via stdin (never in URL/query)

### Remove user
- Confirm username
- Optional: purge home directory
- Block last managed admin
- Explains sequence: lock → terminate sessions → delete account

## View-only mode
- Add / Role / Passwd / Remove hidden or disabled with “read only”
- Table + audit remain visible
