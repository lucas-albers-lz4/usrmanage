# Roadmap

## After first feed publish (`v0.1.0`)

- [x] QEMU feed smoke on x86_64 (24.10.5) — `scripts/validate-feed-smoke.sh`
- [ ] QEMU feed smoke on armsr-armv8 + remaining release lines (25.12)
- [x] LuCI Playwright e2e spotcheck (login + add user vs QEMU lab) — `scripts/playwright-luci.sh` / Playwright MCP
- [ ] QEMU i18n / theme spotchecks
- [x] Password policy presets + live checklist (OpenWrt default; Save to change)
- [x] Zen MCR criticals C1–C7 (actor sanitize, rpcd argv, flock-only lock, jsonfilter, audit denials) — see #3 for remaining majors
- [x] Zen MCR Fix-now majors M1–M3/M5/M7/M10 + audit `--last` / audit-dir mode (integrity PR)
- [x] Publish `0.1.1` with `shadow-*` DEPENDS + password policy + security fixes
- [x] Zen MCR Later M8: LuCI mutator error detail (`ok:false` + `error` in notifications)
- [ ] Zen MCR Later: M9 mutation/lock/rpcd tests; M4/M6 + minors (see #3)
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
