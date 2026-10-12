# User docs screenshots

WebP captures from `scripts/capture-usrmanage-screenshots.mjs` (#15). QEMU lab, OpenWrt 24.10, stock LuCI theme, English UI.

**Hard requirement:** managed-user table must be empty or show only the documented fixture `docuser`. Never commit shots showing `umadmin`, `pwflow_*`, or smoke/e2e leftovers.

| File | Content |
|------|---------|
| `usrmanage-empty.webp` | User Management — empty table, OpenWrt policy |
| `usrmanage-add-dialog.webp` | Add user modal (no password typed) |
| `usrmanage-policy-editor.webp` | Password policy editor |
| `usrmanage-one-user.webp` | Single fixture user `docuser` |

Recapture after UI changes: **[capture-screenshots.md](capture-screenshots.md)**

```sh
npm run test:ui
```
