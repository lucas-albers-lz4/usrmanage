# QEMU matrix results (Phase 4 / #28)

usrmanage from git tree via `ssh cat` on fresh EFI images. 2026-08-08.

## No-shadow (stock) — required acceptance path

| Release | useradd | result | hash |
|---------|---------|--------|------|
| 24.10.8 | absent | PASS | $6$ |
| 25.12.0 | absent | PASS | $6$ |

### 24.10.8
```
no_useradd
PASS_2410_no_shadow
```
Aging after add + passwd (`awk -F: '$1==u{print $4,$5}' /etc/shadow`): `0 99999`

### 25.12.0
```
no_useradd
ok: added m2512b role=readonly
uid=1000(m2512b) gid=1000(m2512b) groups=1000(m2512b)
m2512b:$6$64DbVmUP/w
ok: password updated for m2512b
ok: removed m2512b
PASS_2512_no_shadow
```
Aging after add + passwd (`awk -F: '$1==u{print $4,$5}' /etc/shadow`): `0 99999`

## With-shadow

Deferred until feed publish can `opkg install shadow-*` on lab guests (needs package index). Host `test_mutators-busybox-fallback.sh` covers mixed-provenance bcrypt-shaped lock/delete.

## Host gate

`./scripts/smoke-host.sh` green including busybox-fallback tests.
