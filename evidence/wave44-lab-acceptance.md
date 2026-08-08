# Wave #44 lab acceptance (F1–F6 / v0.1.4)

Date: 2026-08-08. Packages from git tree via `ssh cat` (post-merge `49af90a` + Playwright tour branch).

## QEMU no-shadow CLI

| Release | result | notes |
|---------|--------|-------|
| 24.10.8 | PASS | aging min/max `0 99999` after add + passwd |
| 25.12.0 | (pending below) | |

## Playwright product tour

`./scripts/playwright-luci.sh` against 24.10.8 lab — **3 passed**:

1. login + open User Management
2. add readonly user
3. full tour: add → set-role admin → passwd → policy Standard Save → delete

EN UI; `pwflow_*` usernames; SSH cleanup; traces off.
