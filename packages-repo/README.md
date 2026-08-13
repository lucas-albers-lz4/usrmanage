# usrmanage-packages

Signed OpenWrt package feed for **usrmanage** and **luci-app-usrmanage**.

**Feed:** https://lucas-albers-lz4.github.io/usrmanage-packages/

Source and CI: https://github.com/lucas-albers-lz4/usrmanage

## Key fingerprints (out-of-band verification)

Verify the signing keys against these fingerprints **before** adding them
(fingerprints computed from the live feed; mirrored from the source repo
[`docs/binary-feed.md`](https://github.com/lucas-albers-lz4/usrmanage/blob/main/docs/binary-feed.md)).

| Key file | usign Key ID | SHA-256 |
|----------|-------------|---------|
| `public.key` (opkg) | `f4345260b7ec740d` | `c40bc217f793623e75ea6c77ddb4610b3c6fd64ba3934741ac28754d0e0f970d` |
| `usrmanage-feed.rsa.pub` (apk) | — | `4bb7f1bf54d95b9c490b8c1d5394c347a4db408ecb811a0bab8c4aea2747e5c7` |

## Install

**Recommended — binary feed.** Full guide: [installation](https://github.com/lucas-albers-lz4/usrmanage/blob/main/docs/user/installation.md).

### OpenWrt 24.10 (opkg)

```sh
wget -O /tmp/usrmanage.key https://lucas-albers-lz4.github.io/usrmanage-packages/public.key
echo 'c40bc217f793623e75ea6c77ddb4610b3c6fd64ba3934741ac28754d0e0f970d  /tmp/usrmanage.key' | sha256sum -c - || { echo "FINGERPRINT MISMATCH"; exit 1; }
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
echo '4bb7f1bf54d95b9c490b8c1d5394c347a4db408ecb811a0bab8c4aea2747e5c7  /tmp/usrmanage-feed.rsa.pub' | sha256sum -c - || { echo "FINGERPRINT MISMATCH"; exit 1; }
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
