# SDK build matrix

Cross-build **`usrmanage`** and **`luci-app-usrmanage`** with official [`ghcr.io/openwrt/sdk`](https://github.com/openwrt/docker) images.

## Supported cells (4)

| OpenWrt | Point pin | Targets | Feed format |
|---------|-----------|---------|-------------|
| 24.10 | 24.10.8 | `x86-64`, `armsr-armv8` | opkg (`24.10/`) |
| 25.12 | 25.12.5 | `x86-64`, `armsr-armv8` | apk (`25.12/all/`) |

| Target | Package arch dir |
|--------|------------------|
| `x86-64` | `out/x86_64/<patch>/usrmanage/` |
| `armsr-armv8` | `out/aarch64_generic/<patch>/usrmanage/` |

Packages are **`PKGARCH:=all`**. Dual-arch SDK builds verify compile cleanliness; the signed Pages feed stages **x86-64** `_all` artifacts.

## Commands

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build --target armsr-armv8 --version 25.12
./scripts/docker-sdk.sh build-all   # all 4 cells
```

## Reproducibility

```sh
SOURCE_DATE_EPOCH=1700000000 ./scripts/verify-reproducible-build.sh
./scripts/verify-reproducible-build.sh --version 24.10
```

Double-builds on **x86-64** for 24.10 / 25.12; both packages must SHA-match. Publish CI fails if not.

## Feeds lock

Pinned OpenWrt feed commits live under `scripts/feeds.lock/<patch>/feeds.conf`. Each file pins `base`, `packages`, and `luci` to specific commits (URLs use official GitHub mirrors of git.openwrt.org; pins unchanged). The SDK build appends the local `src-link usrmanage` line at build time.

`docker-compose` bind-mounts host `.ci-sdk-cache/dl` and `.ci-sdk-cache/feeds/<patch>/` over `/builder/dl` and `/builder/feeds` so publish CI (`actions/cache` keyed on `scripts/feeds.lock/**`) and local rebuilds reuse downloads and feed clones.
