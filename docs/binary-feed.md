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

Make sure that the downloaded key is correct **before** you trust it. Compare the SHA-256 hash of the fetched file against the value below.

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
5. **Client migration (luna fold 2026-08-10):** replacing the published
   key causes existing installations to reject newly signed
   indexes/packages unless the new key is distributed and trusted
   first. Preferred: an **overlap period** — publish the new key
   alongside the old (e.g. `public.key.new` / both fingerprints
   listed) and instruct operators to install the new key while the
   old one is still valid; only cut over after the new key is
   distributed. At minimum, the release notes must state that
   operators must re-fetch and re-add the key and make sure that the new
   fingerprint is correct before updating to the post-rotation release.
6. **Format-specific migration (luna r2 2026-08-10):** the mechanics
   differ per package manager — `opkg-key add /tmp/usrmanage.key`
   installs an ADDITIONAL usign key (the old one stays valid, so the
   overlap period works naturally); `apk` requires placing the new
   RSA key under `/etc/apk/keys/usrmanage-feed.rsa.pub` BEFORE
   `apk update`, and the old key must be removed only after the new
   one is trusted. Release notes must provide these format-specific
   commands.

## Signing

| Format | Tool | Public key on Pages |
|--------|------|---------------------|
| opkg | usign | `public.key` |
| apk | openssl RSA | `usrmanage-feed.rsa.pub` |

Secrets live on the **usrmanage** repo (not the packages repo). See [github-publish-checklist.md](github-publish-checklist.md).

## Regenerating `scripts/feeds.lock/`

When bumping a point release pin (`sdk_matrix_version_patch` in `scripts/lib/sdk-matrix.sh`):

1. Pull the matching SDK image: `docker pull ghcr.io/openwrt/sdk:x86-64-<patch>` (e.g. `x86-64-24.10.8`).
2. Copy the SDK default feeds file:
   `docker run --rm --entrypoint cat ghcr.io/openwrt/sdk:x86-64-<patch> /builder/feeds.conf.default`
3. Write `scripts/feeds.lock/<patch>/feeds.conf`:
   - Keep the same feed names / `src-git` style as the SDK default (including `--root=package` / `src-git-full` when present).
   - Rewrite `git.openwrt.org` URLs to the official GitHub mirrors (`github.com/openwrt/{openwrt,packages,luci,routing,telephony,video}.git`).
   - Pin `base` by the **peeled** tag commit (`git ls-remote … refs/tags/v<patch>^{}`), not the annotated tag object.
   - Keep other feed commit pins from the SDK default.
   - Append `src-link usrmanage /work/usrmanage/openwrt-feed`.
4. Retire the unused old `scripts/feeds.lock/<old-patch>/` directory in the same PR.
5. Update `feed_publish_ipkg_index_script` base refs in `scripts/lib/feed-publish.sh` to the same peeled commits; recheck `ipkg-make-index.sh` `sha_expected` (may be unchanged).

See also [developer/build-matrix.md](developer/build-matrix.md).

## Maintainer publish

Tag `v*` → `.github/workflows/publish-packages.yml` builds the 4-cell matrix, makes sure that the build is reproducible, stages the feed, deploys `usrmanage-packages` gh-pages, uploads Release assets.
