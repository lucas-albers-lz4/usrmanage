# Installation

## From the binary feed (recommended)

See [binary-feed.md](../binary-feed.md) for opkg (24.10) and apk (25.12) commands.

Install both:

- `usrmanage` (CLI)
- `luci-app-usrmanage` (web UI)

`usrmanage` depends on `sudo`, `jshn`, and `jsonfilter`. Stock OpenWrt needs no `shadow-*` packages; account create/delete uses busybox `passwd` plus atomic file fallbacks.

```sh
usrmanage doctor
usrmanage list
```

LuCI: **System → User Management**.

## From source feed (firmware builders)

```sh
echo "src-link usrmanage /absolute/path/to/usrmanage/openwrt-feed" >> feeds.conf
./scripts/feeds update usrmanage
./scripts/feeds install usrmanage luci-app-usrmanage
```

## First admin user

```sh
usrmanage add ops --role admin
# password via prompt or --password-fd
```

Wire LuCI for managed users with **Allow LuCI web login** (or `usrmanage set-luci-login`), or manually via `luci-app-acl`. See [roles-and-acl.md](roles-and-acl.md).

