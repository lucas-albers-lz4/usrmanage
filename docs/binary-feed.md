# Binary package feed (GitHub Pages)

Signed **opkg** / **apk** feed for `usrmanage` and `luci-app-usrmanage`:

**https://lucas-albers-lz4.github.io/usrmanage-packages/**

Manual downloads also appear on [GitHub Releases](https://github.com/lucas-albers-lz4/usrmanage/releases).

## Feed layout

```text
usrmanage-packages/   (gh-pages)
  README.md
  public.key              opkg trust
  usrmanage-feed.rsa.pub  apk trust
  manifest.json
  23.05/   *.ipk + Packages{,.gz,.sig}
  24.10/   *.ipk + Packages{,.gz,.sig}
  25.12/all/  *.apk + packages.adb
```

Packages are **`_all`** — one URL per OpenWrt release line (not per CPU).

## Install

### OpenWrt 23.05 / 24.10 (opkg)

```sh
wget -O /tmp/usrmanage.key https://lucas-albers-lz4.github.io/usrmanage-packages/public.key
opkg-key add /tmp/usrmanage.key
echo 'src/gz usrmanage https://lucas-albers-lz4.github.io/usrmanage-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update
opkg install usrmanage luci-app-usrmanage
```

Use `…/23.05` on OpenWrt 23.05.

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

Menu: **System → User Management**.

## Signing

| Format | Tool | Public key on Pages |
|--------|------|---------------------|
| opkg | usign | `public.key` |
| apk | openssl RSA | `usrmanage-feed.rsa.pub` |

Secrets live on the **usrmanage** repo (not the packages repo). See [github-publish-checklist.md](github-publish-checklist.md).

## Maintainer publish

Tag `v*` → `.github/workflows/publish-packages.yml` builds the 6-cell matrix, verifies reproducibility, stages the feed, deploys `usrmanage-packages` gh-pages, uploads Release assets.
