# Wave #44 lab acceptance (F1–F6 / v0.1.4)

Date: 2026-08-08. Packages from git tree via `ssh cat` (post-merge hardening `49af90a` + Playwright tour).

## QEMU no-shadow CLI

Shadow aging asserted by smoke (`awk -F: '$1==u{print $4,$5}' /etc/shadow`) after add + passwd.
Re-confirmed 2026-08-08 on #50 tree (ssh cat of lib/CLI):

| Release | result | aging raw (`$4 $5`) |
|---------|--------|---------------------|
| 24.10.8 | PASS | `0 99999` |
| 25.12.0 | PASS | `0 99999` |

Host mirror: `tests/test_mutators-busybox-fallback.sh` asserts the same `0 99999` string after placeholder and after `$6$` hash.
BusyBox flock on both releases: `-sxun` only (no `-w`) — lock timeout deferred; indefinite wait documented in `um_with_lock`.

## Playwright product tour

`./scripts/playwright-luci.sh` against 24.10.8 lab — **3 passed**:

1. login + open User Management
2. add readonly user
3. full tour: add → set-role admin → passwd → policy Standard Save → delete

EN UI; `pwflow_*` usernames; SSH cleanup; traces off.
