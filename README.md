# usrmanage

[![Tests](https://github.com/lucas-albers-lz4/usrmanage/actions/workflows/usrmanage-test.yml/badge.svg)](https://github.com/lucas-albers-lz4/usrmanage/actions/workflows/usrmanage-test.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

Hardened **local UNIX user management** for OpenWrt (CLI + LuCI): add/remove users, **readonly** vs **admin** (`wheel` + `sudo`), compact **operational audit log**.

Designed for deployments **without** RADIUS/central auth. Supported: **OpenWrt 24.10 / 25.12**, arch-independent packages (ARM + x86_64). (23.05: last release v0.1.2.)

## Packages

| Package | Description |
|---------|-------------|
| `usrmanage` | `/usr/sbin/usrmanage` + library + sudoers + managed-user registry |
| `luci-app-usrmanage` | System → User Management UI + rpcd + read/write ACL |

## Install (binary feed)

**Recommended — [binary feed](docs/binary-feed.md).** Run this on the router. It installs both packages.

**Verify the signing key before trusting it** (fingerprints are published in [docs/binary-feed.md](docs/binary-feed.md) and the [`usrmanage-packages` README](https://github.com/lucas-albers-lz4/usrmanage-packages)):

| Key file | usign Key ID | SHA-256 |
|----------|-------------|---------|
| `public.key` (opkg) | `f4345260b7ec740d` | `c40bc217f793623e75ea6c77ddb4610b3c6fd64ba3934741ac28754d0e0f970d` |
| `usrmanage-feed.rsa.pub` (apk) | — | `4bb7f1bf54d95b9c490b8c1d5394c347a4db408ecb811a0bab8c4aea2747e5c7` |

**OpenWrt 24.10 (opkg):**

```sh
wget -O /tmp/usrmanage.key https://lucas-albers-lz4.github.io/usrmanage-packages/public.key
echo 'c40bc217f793623e75ea6c77ddb4610b3c6fd64ba3934741ac28754d0e0f970d  /tmp/usrmanage.key' | sha256sum -c - || { echo "FINGERPRINT MISMATCH"; exit 1; }
opkg-key add /tmp/usrmanage.key
echo 'src/gz usrmanage https://lucas-albers-lz4.github.io/usrmanage-packages/24.10' >> /etc/opkg/customfeeds.conf
opkg update && opkg install usrmanage luci-app-usrmanage
```

**OpenWrt 25.12 (apk):**

```sh
wget -O /tmp/usrmanage-feed.rsa.pub https://lucas-albers-lz4.github.io/usrmanage-packages/usrmanage-feed.rsa.pub
echo '4bb7f1bf54d95b9c490b8c1d5394c347a4db408ecb811a0bab8c4aea2747e5c7  /tmp/usrmanage-feed.rsa.pub' | sha256sum -c - || { echo "FINGERPRINT MISMATCH"; exit 1; }
mkdir -p /etc/apk/keys
cp /tmp/usrmanage-feed.rsa.pub /etc/apk/keys/usrmanage-feed.rsa.pub
echo 'https://lucas-albers-lz4.github.io/usrmanage-packages/25.12/all/packages.adb' \
  >> /etc/apk/repositories.d/usrmanage.list
apk update && apk add usrmanage luci-app-usrmanage
```

**After install:** create your first admin user — [installation guide](docs/user/installation.md#first-admin-user).

<details>
<summary>Other install methods</summary>

**GitHub Releases:** download the package for your OpenWrt version and install manually — [installation guide](docs/user/installation.md#github-release-manual-download).

**Build from source feed** (firmware builders):

```sh
echo "src-link usrmanage /absolute/path/to/usrmanage/openwrt-feed" >> feeds.conf
./scripts/feeds update usrmanage
./scripts/feeds install usrmanage luci-app-usrmanage
```

</details>

## CLI (summary)

```text
usrmanage list [--json] [--all]
usrmanage add <user> --role readonly|admin [--password-fd N]
usrmanage set-role <user> --role readonly|admin
usrmanage passwd <user> [--password-fd N]
usrmanage del <user> [--purge-home]
usrmanage audit [--json]
usrmanage doctor
```

## Documentation

### Developer

| Doc | Purpose |
|-----|---------|
| [docs/developer/architecture.md](docs/developer/architecture.md) | Architecture |
| [docs/developer/cli-and-api.md](docs/developer/cli-and-api.md) | CLI / ubus / audit schema |
| [docs/developer/luci-ux.md](docs/developer/luci-ux.md) | UI, themes, i18n |
| [docs/developer/testing.md](docs/developer/testing.md) | Unit, integration, Playwright MCP / e2e |
| [docs/developer/build-matrix.md](docs/developer/build-matrix.md) | SDK 4-cell matrix |

### Security

| Doc | Purpose |
|-----|---------|
| [docs/threat-model.md](docs/threat-model.md) | Threat model |
| [docs/security.md](docs/security.md) | Security guidance |
| [docs/security-review.md](docs/security-review.md) | Security audit ledger |

### User

| Doc | Purpose |
|-----|---------|
| [docs/user/installation.md](docs/user/installation.md) | End-user install |
| [docs/user/roles-and-acl.md](docs/user/roles-and-acl.md) | Roles + LuCI ACL |

### Release & feed

| Doc | Purpose |
|-----|---------|
| [docs/binary-feed.md](docs/binary-feed.md) | Signed opkg/apk feed |
| [docs/release.md](docs/release.md) | Tag → publish |
| [docs/github-publish-checklist.md](docs/github-publish-checklist.md) | Secrets / Pages setup |
| [docs/supported-releases.md](docs/supported-releases.md) | 24.10 / 25.12 (23.05 → v0.1.2) |

### Project

| Doc | Purpose |
|-----|---------|
| [docs/ROADMAP.md](docs/ROADMAP.md) | Next steps |
| [docs/upstream.md](docs/upstream.md) | Upstream OpenWrt path |

## Host checks

```sh
./scripts/smoke-host.sh
```

With a running QEMU lab (LuCI on `:8080`), LuCI e2e:

```sh
npm install && npx playwright install chromium
./scripts/playwright-luci.sh
```

See [docs/developer/testing.md](docs/developer/testing.md).

## Agent guidance

See **[AGENTS.md](AGENTS.md)** (and [CLAUDE.md](CLAUDE.md)) for product locks, LuCI/rpc conventions, and security invariants.

## QEMU lab (x86_64)

Place an OpenWrt combined ext4 image at `lab/images/openwrt-x86-64-24.10.8.img`, then:

```sh
sudo OWRT_IMG=lab/images/openwrt-x86-64-24.10.8.img ./scripts/qemu-lab-prepare-image.sh
./scripts/validate-feed-smoke.sh --version 24.10
# or stepwise:
#   OWRT_QEMU_DAEMON=1 OWRT_RELEASE=24.10.8 ./scripts/run-openwrt-x86-qemu.sh
#   ./scripts/qemu-wait-guest.sh
#   ./scripts/qemu-install-from-feed.sh --version 24.10
./scripts/run-openwrt-x86-qemu.sh --stop
```

SSH `ssh -p 2222 root@localhost` · LuCI http://localhost:8080/cgi-bin/luci/

## License

Apache-2.0 — see [LICENSE](LICENSE).
