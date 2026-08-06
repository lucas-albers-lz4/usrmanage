# usrmanage

Hardened **local UNIX user management** for OpenWrt (CLI + LuCI): add/remove users, **readonly** vs **admin** (`wheel` + `sudo`), compact **operational audit log**.

Designed for deployments **without** RADIUS/central auth. Supported: **OpenWrt 23.05 / 24.10 / 25.12**, arch-independent packages (ARM + x86_64).

## Packages

| Package | Description |
|---------|-------------|
| `usrmanage` | `/usr/sbin/usrmanage` + library + sudoers + managed-user registry |
| `luci-app-usrmanage` | System → User Management UI + rpcd + read/write ACL |

## Install (binary feed)

See **[docs/binary-feed.md](docs/binary-feed.md)** and **[docs/user/installation.md](docs/user/installation.md)**.

Feed: https://lucas-albers-lz4.github.io/usrmanage-packages/

## Build from source feed

```sh
echo "src-link usrmanage /absolute/path/to/usrmanage/openwrt-feed" >> feeds.conf
./scripts/feeds update usrmanage
./scripts/feeds install usrmanage luci-app-usrmanage
```

## CLI (summary)

```text
usrmanage list [--json] [--all]
usrmanage add <user> --role readonly|admin [--password-fd N]
usrmanage set-role <user> readonly|admin
usrmanage passwd <user> [--password-fd N]
usrmanage del <user> [--purge-home]
usrmanage audit [--json]
usrmanage doctor
```

## Documentation

| Doc | Purpose |
|-----|---------|
| [docs/developer/architecture.md](docs/developer/architecture.md) | Architecture |
| [docs/developer/cli-and-api.md](docs/developer/cli-and-api.md) | CLI / ubus / audit schema |
| [docs/developer/luci-ux.md](docs/developer/luci-ux.md) | UI, themes, i18n |
| [docs/developer/build-matrix.md](docs/developer/build-matrix.md) | SDK 6-cell matrix |
| [docs/binary-feed.md](docs/binary-feed.md) | Signed opkg/apk feed |
| [docs/release.md](docs/release.md) | Tag → publish |
| [docs/github-publish-checklist.md](docs/github-publish-checklist.md) | Secrets / Pages setup |
| [docs/user/installation.md](docs/user/installation.md) | End-user install |
| [docs/user/roles-and-acl.md](docs/user/roles-and-acl.md) | Roles + LuCI ACL |
| [docs/threat-model.md](docs/threat-model.md) | Threat model |
| [docs/security.md](docs/security.md) | Security guidance |
| [docs/supported-releases.md](docs/supported-releases.md) | 23.05 / 24.10 / 25.12 |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Next steps |
| [docs/upstream.md](docs/upstream.md) | Upstream OpenWrt path |

## Host checks

```sh
./scripts/smoke-host.sh
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
