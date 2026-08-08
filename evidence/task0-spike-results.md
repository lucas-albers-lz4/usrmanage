# Task 0 spike results (Phase 1 / #25)

Stock OpenWrt x86_64 EFI combined-ext4 images, prepared with `scripts/qemu-lab-prepare-image.sh` (LAN DHCP for QEMU user-net). **No shadow-* packages installed.**

Probe date: 2026-08-08. Lab: QEMU KVM, SSH `127.0.0.1:2222`.

## Summary

| Check | 24.10.8 | 25.12.0 |
|-------|---------|---------|
| Stock has no useradd/userdel/usermod/chpasswd/gpasswd | PASS | PASS |
| `/etc/passwd` mode/owner (`ls -ldn`) | PASS `0644` `0:0` | PASS `0644` `0:0` |
| `/etc/group` mode/owner | PASS `0644` `0:0` | PASS `0644` `0:0` |
| `/etc/shadow` mode/owner | PASS `0600` `0:0` | PASS `0600` `0:0` |
| Piped `passwd -a sha512` exit 0 | PASS | PASS |
| Hash prefix `$6$` after piped passwd | PASS | PASS |
| awk: locked / empty / expiry shadow field counts | PASS (NF=8) | PASS (NF=8) |
| awk: passwd colon-in-GECOS / short line | PASS (NF 10 / 3) | PASS (NF 10 / 3) |
| awk: group empty / long member list | PASS | PASS |

**Hard gate:** piped `passwd -a sha512` works on both releases → Phase 2 may proceed.

## 24.10.8

- `DISTRIB_RELEASE='24.10.8'` (`r29233-443ec4032a`)
- Image: `openwrt-24.10.8-x86-64-generic-ext4-combined-efi.img`
- Modes: `passwd`/`group` `-rw-r--r-- 0:0`; `shadow` `-rw------- 0:0`
- Scratch user `t0spike`: `printf '%s\n%s\n' "$pw" "$pw" | passwd -a sha512 t0spike` → exit 0, hash starts with `$6$`
- Note: busybox passwd briefly logged `no record … in /etc/shadow, using /etc/passwd` when the placeholder was a fresh append; it still wrote a `$6$` shadow hash successfully

## 25.12.0

- `DISTRIB_RELEASE='25.12.0'` (`r32713-f919e7899d`)
- Image: `openwrt-25.12.0-x86-64-generic-ext4-combined-efi.img`
- Same mode/ownership and `$6$` results as 24.10.8
- Stock `network` UCI uses `list ipaddr '…/nn'` (prepare script updated to rewrite to DHCP)

## awk probe detail (both)

| Input shape | Observed |
|-------------|----------|
| shadow locked `!$6$…` | NF=8, field2 starts `!$6` |
| shadow empty hash | NF=8, field2 empty |
| shadow expiry (8 fields) | NF=8, field2 `$6$` |
| passwd normal | NF=7 |
| passwd GECOS with colons | NF=10 (colon-split GECOS) |
| passwd short (3 fields) | NF=3 |
| group empty members | NF=4, member length 0 |
| group long members | NF=4, member length 19 |

## Lab prepare fix (supporting)

`scripts/qemu-lab-prepare-image.sh` now rewrites the lan section through next `config`/EOF (not only through a blank line) and drops both classic `option ipaddr/netmask` and 25.12 `list ipaddr` forms so stock images get DHCP under QEMU slirp.
