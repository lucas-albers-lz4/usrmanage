# Roadmap

## After first feed publish (`v0.1.0`)

- [ ] QEMU feed smoke on x86_64 and armsr-armv8 guests (23.05 / 24.10 / 25.12)
- [ ] QEMU i18n / theme spotchecks
- [ ] Document observed BusyBox / sudo versions per release line
- [ ] Optional: PR CI single-cell SDK compile (cost vs coverage)

## Later

- [ ] Optional `--luci-login` helper (still prefer explicit `luci-app-acl` on hardened boxes)
- [ ] Upstream PRs to `openwrt/packages` + `openwrt/luci` ([upstream.md](upstream.md))
- [ ] Remote syslog deployment examples for audit retention

## Explicitly not planned soon

- OpenWrt 21.02 / 22.03
- Cryptographic signing of the local audit file
- RADIUS / LDAP / TACACS+
