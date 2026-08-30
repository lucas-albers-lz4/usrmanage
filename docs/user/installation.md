# Installation

Most users install from the **[binary feed](#from-the-binary-feed-recommended)**. It needs no manual download. When the feed does not work for you, use the other methods.

## From the binary feed (recommended)

Install both packages:

- `usrmanage` (CLI)
- `luci-app-usrmanage` (web UI)

`usrmanage` depends on `sudo`, `jshn`, and `jsonfilter`. Stock OpenWrt needs no `shadow-*` packages. Account create/delete uses busybox `passwd` plus atomic file fallbacks.

**OpenWrt 24.10 (opkg):**

```sh
wget -O /tmp/usrmanage.key https://lucas-albers-lz4.github.io/usrmanage-packages/public.key
echo 'c40bc217f793623e75ea6c77ddb4610b3c6fd64ba3934741ac28754d0e0f970d  /tmp/usrmanage.key' | sha256sum -c - || { echo "FINGERPRINT MISMATCH – key may be tampered"; exit 1; }
opkg-key add /tmp/usrmanage.key
echo 'src/gz usrmanage https://lucas-albers-lz4.github.io/usrmanage-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update
opkg install usrmanage luci-app-usrmanage
```

OpenWrt 23.05 operators: install **v0.1.2** from the historical `23.05/` feed directory. Details: [supported-releases.md](../supported-releases.md#2305-deprecation).

**OpenWrt 25.12 (apk):**

```sh
wget -O /tmp/usrmanage-feed.rsa.pub https://lucas-albers-lz4.github.io/usrmanage-packages/usrmanage-feed.rsa.pub
echo '4bb7f1bf54d95b9c490b8c1d5394c347a4db408ecb811a0bab8c4aea2747e5c7  /tmp/usrmanage-feed.rsa.pub' | sha256sum -c - || { echo "FINGERPRINT MISMATCH – key may be tampered"; exit 1; }
mkdir -p /etc/apk/keys
cp /tmp/usrmanage-feed.rsa.pub /etc/apk/keys/usrmanage-feed.rsa.pub
echo 'https://lucas-albers-lz4.github.io/usrmanage-packages/25.12/all/packages.adb' \
  >> /etc/apk/repositories.d/usrmanage.list
apk update
apk add usrmanage luci-app-usrmanage
```

Make sure that the install works:

```sh
usrmanage doctor
usrmanage list
```

LuCI: **System → User Management**.

More detail: [binary-feed.md](../binary-feed.md).

<details>
<summary>Other install methods</summary>

Use these methods when the binary feed does not work for you. Most users do not need them.

## GitHub Release (manual download)

Download the prebuilt package from **[GitHub Releases](https://github.com/lucas-albers-lz4/usrmanage/releases)** for your OpenWrt version.

| OpenWrt | Artifact | Package manager |
|---------|----------|-----------------|
| **24.10** | `usrmanage_*_24.10_all.ipk` + `luci-app-usrmanage_*_24.10_all.ipk` | `opkg` |
| **25.12** | `usrmanage-*.apk` + `luci-app-usrmanage-*.apk` | `apk` |

The packages are **`_all`** — architecture-independent. One `.ipk` or `.apk` per OpenWrt release works on any router (ARM, x86, and more).

Copy to the router and install:

**OpenWrt 24.10 (opkg):**

```sh
scp usrmanage_*.ipk luci-app-usrmanage_*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 opkg install /tmp/usrmanage_*.ipk /tmp/luci-app-usrmanage_*.ipk
```

**OpenWrt 25.12 (apk):**

```sh
scp usrmanage-*.apk luci-app-usrmanage-*.apk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 apk add --allow-untrusted /tmp/usrmanage-*.apk /tmp/luci-app-usrmanage-*.apk
```

## From source feed (firmware builders)

```sh
echo "src-link usrmanage /absolute/path/to/usrmanage/openwrt-feed" >> feeds.conf
./scripts/feeds update usrmanage
./scripts/feeds install usrmanage luci-app-usrmanage
```

See [openwrt-feed/README.md](../../openwrt-feed/README.md) for the full builder flow.

</details>

## First admin user

```sh
usrmanage add ops --role admin
# password via prompt or --password-fd
```

Wire LuCI for managed users with **Allow LuCI web login** (or `usrmanage set-luci-login`), or manually via `luci-app-acl`. See [roles-and-acl.md](roles-and-acl.md).

