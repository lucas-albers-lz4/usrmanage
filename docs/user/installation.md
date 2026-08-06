# Installation

## From the binary feed (recommended)

See [binary-feed.md](../binary-feed.md) for opkg (23.05 / 24.10) and apk (25.12) commands.

Install both:

- `usrmanage` (CLI)
- `luci-app-usrmanage` (web UI)

Then:

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

Wire LuCI web logins separately with `luci-app-acl` (`$p$ops` for shadow). See [roles-and-acl.md](roles-and-acl.md).
