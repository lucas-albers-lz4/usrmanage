# SDK build matrix

Cross-build **`usrmanage`** and **`luci-app-usrmanage`** with official [`ghcr.io/openwrt/sdk`](https://github.com/openwrt/docker) images.

## Supported cells (6)

| OpenWrt | Point pin | Targets | Feed format |
|---------|-----------|---------|-------------|
| 24.10 | 24.10.5 | `x86-64`, `armsr-armv8` | opkg (`24.10/`) |
| 25.12 | 25.12.0 | `x86-64`, `armsr-armv8` | apk (`25.12/all/`) |

| Target | Package arch dir |
|--------|------------------|
| `x86-64` | `out/x86_64/<patch>/usrmanage/` |
| `armsr-armv8` | `out/aarch64_generic/<patch>/usrmanage/` |

Packages are **`PKGARCH:=all`**. Dual-arch SDK builds verify compile cleanliness; the signed Pages feed stages **x86-64** `_all` artifacts.

## Commands

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build-all   # all 6 cells
```

## Reproducibility

```sh
SOURCE_DATE_EPOCH=1700000000 ./scripts/verify-reproducible-build.sh
./scripts/verify-reproducible-build.sh --version 24.10
```

Double-builds on **x86-64** for 24.10 / 25.12; both packages must SHA-match. Publish CI fails if not.

## Feeds lock

Pinned OpenWrt feed commits live under `scripts/feeds.lock/<patch>/feeds.conf`. Each file pins `base`, `packages`, and `luci` to specific commits (URLs use official GitHub mirrors of git.openwrt.org; pins unchanged). The SDK build appends the local `src-link usrmanage` line at build time.
