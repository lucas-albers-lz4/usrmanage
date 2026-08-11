# Roadmap

## Shipped

- [x] Shadow-free stock installs (v0.1.3 busybox fallbacks; v0.1.4 hardening)
- [x] QEMU feed smoke on x86_64 (24.10) — `scripts/validate-feed-smoke.sh`
- [x] LuCI Playwright e2e (login + product tour vs QEMU lab) — `scripts/playwright-luci.sh`
- [x] Password policy presets + live checklist (OpenWrt default; Save to change)
- [x] issue #3 criticals C1–C7 + Fix-now majors; LuCI mutator error detail (M8)
- [x] Host mutator/lock/rpcd tests (M9) via `tests/test_mutators.sh` + busybox-fallback
- [x] OpenWrt 23.05 deprecated; support matrix 24.10 / 25.12 only

## Post-0.1.4 wave ([#52](https://github.com/lucas-albers-lz4/usrmanage/issues/52) — closed)

- [x] #50 follow-up hardening (F2 recovery path, tx-begin leak, E2E policy reset, lock timeout)
- [x] #51 parity gates (actor sanitize, preset tables, APP_VERSION)
- [x] #47 Fowler refactor pass (after #50)

## Open follow-ups

- [ ] #15 docs WebP screenshots (clean lab; WIP branch `feat/15-docs-screenshots`)
- [ ] Release tag after lab acceptance (`docs/release.md`)

## Later

- [ ] QEMU feed smoke on armsr-armv8 + remaining release lines
- [ ] QEMU i18n / theme spotchecks
- [ ] With-shadow QEMU combos (needs feed package index)
- [ ] Document observed BusyBox / sudo versions per release line
- [ ] Optional: PR CI single-cell SDK compile (cost vs coverage)
- [x] Opt-in LuCI login lifecycle (`set-luci-login` + UI) — [#86](https://github.com/lucas-albers-lz4/usrmanage/issues/86)
- [ ] Upstream PRs to `openwrt/packages` + `openwrt/luci` ([upstream.md](upstream.md))
- [ ] Remote syslog deployment examples for audit retention

## Explicitly not planned soon

- OpenWrt 21.02 / 22.03 / 23.05
- Cryptographic signing of the local audit file
- RADIUS / LDAP / TACACS+
