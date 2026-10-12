# Capturing User Management screenshots

Repeatable steps for updating WebP images in this directory from the QEMU x86 lab.

## Prerequisites

- Linux host with QEMU and Node.js
- Playwright (one-time): `npm install` then `npx playwright install chromium`
- Prepared guest with `usrmanage` + `luci-app-usrmanage` installed

The capture script does **not** boot QEMU. Start the guest and install packages first (same as e2e).

## Lab setup

```sh
./scripts/run-openwrt-x86-qemu.sh --stop
OWRT_QEMU_DAEMON=1 OWRT_RELEASE=24.10.8 ./scripts/run-openwrt-x86-qemu.sh
MAX_WAIT=300 ./scripts/qemu-wait-guest.sh
./scripts/qemu-install-from-feed.sh --version 24.10 --no-smoke
```

Use `--no-smoke` so qemu-smoke fixtures (`umadmin`, `umsmoke`) are not created. The capture script deletes leftover managed users, including a lab-only last-admin unwind, and refuses to write shots if those names are still visible.

LuCI: http://localhost:8080/cgi-bin/luci/admin/system/usrmanage (login: `root`, empty password on prepared images)

## Automated capture

```sh
npm run test:ui
```

Or:

```sh
USRMANAGE_LUCI_URL=http://127.0.0.1:8080 node scripts/capture-usrmanage-screenshots.mjs
```

Order of operations inside the script:

1. SSH: delete managed users that are not the documented fixture, reset OpenWrt policy, truncate the audit log
2. Strip the prepared-image “No password set” LuCI nag and the package version chip (lab artifacts; not product UI)
3. Empty table → `usrmanage-empty.webp`
4. Open Add user, fill fixture username only (password fields stay empty) → `usrmanage-add-dialog.webp`
5. Open Configure (policy editor) → `usrmanage-policy-editor.webp`
6. SSH-add fixture `docuser` (password on stdin / `--password-fd`) → `usrmanage-one-user.webp`
7. `finally`: delete the fixture

Writes:

| File | Content |
|------|---------|
| `usrmanage-empty.webp` | User Management — empty table, OpenWrt policy strip |
| `usrmanage-add-dialog.webp` | Add user modal (username `docuser`; passwords not filled) |
| `usrmanage-policy-editor.webp` | Password policy editor (OpenWrt preset) |
| `usrmanage-one-user.webp` | Single fixture row `docuser` (readonly) |
| `usrmanage-debug.webp` | Failure-only; gitignored |

English UI only. Stock LuCI theme. Viewport 1440×900. Playwright 1.60 writes PNG; the script encodes WebP with `ffmpeg -c:v libwebp` (quality 85).

## Hard requirements

- Never commit shots that show `umadmin`, `umsmoke`, `pwflow_*`, or other smoke/e2e leftovers
- Passwords never on argv, never typed into screenshot fields, never in Playwright traces
- Fixture name is **`docuser`** only; created after the empty/dialog/policy shots and removed afterward
