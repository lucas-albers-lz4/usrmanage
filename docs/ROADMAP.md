# Roadmap

## After first feed publish (`v0.1.0`)

- [x] QEMU feed smoke on x86_64 (24.10.5) — `scripts/validate-feed-smoke.sh`
- [ ] QEMU feed smoke on armsr-armv8 + remaining release lines (23.05 / 25.12)
- [ ] QEMU i18n / theme spotchecks
- [x] Password policy presets + live checklist (OpenWrt default; Save to change)
- [x] Zen MCR criticals C1–C7 (actor sanitize, rpcd argv, flock-only lock, jsonfilter, audit denials) — see #3 for remaining majors
- [ ] Publish `0.1.0-r2` with `shadow-*` DEPENDS + password policy + security fixes
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
