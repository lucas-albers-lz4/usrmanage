# Upstream path (OpenWrt)

Target after field hardening on 24.10 + 25.12:

| Package | Proposed tree | Notes |
|---------|---------------|--------|
| `usrmanage` | [openwrt/packages](https://github.com/openwrt/packages) `admin/` or `utils/` | CLI + sudoers + registry |
| `luci-app-usrmanage` | [openwrt/luci](https://github.com/openwrt/luci) `applications/` | JS view + rpcd + ACL |

## Checklist before PR

- [ ] Apache-2.0 SPDX on all sources; `PKG_LICENSE` / `LUCI` metadata set
- [ ] No gov-only hooks in core
- [ ] README distinguishes UNIX users vs `luci-app-acl` web logins
- [ ] Document intentional `%wheel` full-sudo boundary
- [ ] `po/` templates present; ShellCheck clean; ash-safe
- [ ] CI builds against openwrt-24.10 and openwrt-25.12
- [ ] Security notes + threat model linked from package description

## Staging

1. Develop in this repo (`openwrt-feed/`)
2. Optional private binary feed (fwlive-packages pattern)
3. Field use + security review
4. Submit PRs to packages + luci
