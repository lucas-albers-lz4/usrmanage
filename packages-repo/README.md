# usrmanage-packages

Signed OpenWrt package feed for **usrmanage** and **luci-app-usrmanage**.

**Feed:** https://lucas-albers-lz4.github.io/usrmanage-packages/

Source and CI: https://github.com/lucas-albers-lz4/usrmanage

## Install

**Recommended — binary feed.** Full guide: [installation](https://github.com/lucas-albers-lz4/usrmanage/blob/main/docs/user/installation.md).

### OpenWrt 24.10 (opkg)

```sh
wget -O /tmp/usrmanage.key https://lucas-albers-lz4.github.io/usrmanage-packages/public.key
opkg-key add /tmp/usrmanage.key
echo 'src/gz usrmanage https://lucas-albers-lz4.github.io/usrmanage-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update
opkg install usrmanage luci-app-usrmanage
```

OpenWrt 23.05: stay on v0.1.2 (`…/23.05` historical feed).

<details>
<summary>OpenWrt 25.12 (apk) and more detail</summary>

### OpenWrt 25.12 (apk)

```sh
wget -O /tmp/usrmanage-feed.rsa.pub https://lucas-albers-lz4.github.io/usrmanage-packages/usrmanage-feed.rsa.pub
mkdir -p /etc/apk/keys
cp /tmp/usrmanage-feed.rsa.pub /etc/apk/keys/usrmanage-feed.rsa.pub
echo 'https://lucas-albers-lz4.github.io/usrmanage-packages/25.12/all/packages.adb' \
  >> /etc/apk/repositories.d/usrmanage.list
apk update
apk add usrmanage luci-app-usrmanage
```

More detail: [binary feed](https://github.com/lucas-albers-lz4/usrmanage/blob/main/docs/binary-feed.md) · [installation guide](https://github.com/lucas-albers-lz4/usrmanage/blob/main/docs/user/installation.md)

</details>

Menu after install: **System → User Management**.

This repository’s `gh-pages` branch is written by CI. Do not edit package binaries by hand.
