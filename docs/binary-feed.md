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
  24.10/   *.ipk + Packages{,.gz,.sig}
  25.12/all/  *.apk + packages.adb
```

Packages are **`_all`** — one URL per OpenWrt release line (not per CPU).

`manifest.json` records package sha256 hashes **and** the resolved digest of each of the 4 SDK image cells (24.10/25.12 × x86-64/armsr-armv8) used to build the feed.

## Install

### OpenWrt 24.10 (opkg)

```sh
wget -O /tmp/usrmanage.key https://lucas-albers-lz4.github.io/usrmanage-packages/public.key
echo 'c40bc217f793623e75ea6c77ddb4610b3c6fd64ba3934741ac28754d0e0f970d  /tmp/usrmanage.key' | sha256sum -c - || { echo "FINGERPRINT MISMATCH – key may be tampered"; exit 1; }
opkg-key add /tmp/usrmanage.key
echo 'src/gz usrmanage https://lucas-albers-lz4.github.io/usrmanage-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update
opkg install usrmanage luci-app-usrmanage
```

OpenWrt 23.05 operators: use the last published **v0.1.2** artifacts under the historical `23.05/` feed directory.

### OpenWrt 25.12 (apk)

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

Menu: **System → User Management**.

## Key fingerprints

Verify the downloaded key **before** trusting it. Compare the SHA-256 hash of the fetched file against the value below.

| Key file | usign Key ID | SHA-256 |
|----------|-------------|---------|
| `public.key` (opkg) | `f4345260b7ec740d` | `c40bc217f793623e75ea6c77ddb4610b3c6fd64ba3934741ac28754d0e0f970d` |
| `usrmanage-feed.rsa.pub` (apk) | — | `4bb7f1bf54d95b9c490b8c1d5394c347a4db408ecb811a0bab8c4aea2747e5c7` |

These fingerprints are published in **two independent origins** (this repo and the [`usrmanage-packages` README](https://github.com/lucas-albers-lz4/usrmanage-packages)) for out-of-band cross-checking.

**Fingerprint commands** (for reproducibility):

```sh
# opkg (usign) key
curl -sL https://lucas-albers-lz4.github.io/usrmanage-packages/public.key -o /tmp/usrmanage.key
usign -F -p /tmp/usrmanage.key            # → f4345260b7ec740d
sha256sum /tmp/usrmanage.key              # → c40bc217...

# apk (RSA) key
curl -sL https://lucas-albers-lz4.github.io/usrmanage-packages/usrmanage-feed.rsa.pub -o /tmp/usrmanage-feed.rsa.pub
sha256sum /tmp/usrmanage-feed.rsa.pub     # → 4bb7f1bf...
```

## Rotation procedure

When a signing key is rotated:

1. Generate the new key pair (CI secret `OPKG_SECRET` / `APK_SECRET`).
2. Compute new fingerprints with the commands above.
3. Update the table in **both** this file and the `usrmanage-packages` README **in the same release**.
4. Publish the new feed under the existing URL; old packages remain signed by the previous key until replaced.

## Signing

| Format | Tool | Public key on Pages |
|--------|------|---------------------|
| opkg | usign | `public.key` |
| apk | openssl RSA | `usrmanage-feed.rsa.pub` |

Secrets live on the **usrmanage** repo (not the packages repo). See [github-publish-checklist.md](github-publish-checklist.md).

## Maintainer publish

Tag `v*` → `.github/workflows/publish-packages.yml` builds the 4-cell matrix, verifies reproducibility, stages the feed, deploys `usrmanage-packages` gh-pages, uploads Release assets.
