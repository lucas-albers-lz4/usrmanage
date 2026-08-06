# Supported releases

| OpenWrt | Package format | SDK targets | Status |
|---------|----------------|-------------|--------|
| 23.05 | `.ipk` (opkg) | x86-64, armsr-armv8 | Supported |
| 24.10 | `.ipk` (opkg) | x86-64, armsr-armv8 | Supported |
| 25.12 | `.apk` (apk) | x86-64, armsr-armv8 | Supported |
| ≤22.03 | — | — | **Unsupported** |

Packages are **arch-independent** (`PKGARCH:=all` / `LUCI_PKGARCH:=all`): one artifact per release line covers aarch64 and x86_64. CI still builds both SDK targets (6 cells) to verify compile cleanliness.

Point pins: **23.05.5**, **24.10.5**, **25.12.0** (see [build-matrix.md](developer/build-matrix.md)).

## Smoke expectations

Per release line:

1. One **x86_64** image (QEMU acceptable)
2. One **ARM** / aarch64 image

Checks: install both packages, `usrmanage doctor`, add/list/set-role/passwd/del, LuCI page, audit events, read-only ACL cannot call write methods.

## 23.05 note

LuCI on 23.05 is older than 24.10/25.12. The app uses modern JS views (`view.extend` + `rpc.declare`). Validate on 23.05 before relying on it in production; file gaps under issues if APIs differ.
