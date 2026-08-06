# Security review notes (pre-0.1.0)

Date: 2026-08-05  
Scope: `openwrt-feed/usrmanage`, `openwrt-feed/luci-app-usrmanage`, docs, host tests.

## Architecture checklist

| Item | Status |
|------|--------|
| Single CLI code path for LuCI + shell | Pass — rpcd wraps `/usr/sbin/usrmanage` |
| Split read/write rpcd ACL | Pass — `list/show/audit/doctor` vs `add/del/set_role/passwd` |
| Managed-user registry | Pass — `/etc/usrmanage/users` |
| Last managed admin guard | Pass — demote/delete |
| Lock → kill → delete sequence | Pass — `um_mut_del` |
| Exclusive op lock | Pass — `flock` (BusyBox default; no mkdir fallback) |
| Password not in argv | Pass — `--password-fd` / stdin |
| Actor attribution | Pass — CLI id; LuCI session best-effort / `unknown` |
| Operational audit claim documented | Pass — `docs/security.md` |
| Ash-safe / ShellCheck | Pass — `./scripts/shellcheck.sh` |
| Arch-independent packaging | Pass — `PKGARCH`/`LUCI_PKGARCH:=all` |

## Findings (accepted / residual)

1. **Password still traverses ubus JSON** from LuCI to rpcd (platform pattern; stock LuCI does the same for `setPassword`). Mitigations: TLS ops requirement, never argv, never audit/syslog, clear after pipe. Residual risk: cleartext HTTP or ubus debug logs — operator/config issue.
2. **`hasWriteAcl()` UI gating** is best-effort via `L.hasViewPermission()` / env ACLs; **server ACL is authoritative**. Readonly sessions must be granted read-only ACL via `luci-app-acl`.
3. **Session actor** may be `unknown` if rpcd does not expose username in env — never invents `root` for LuCI.
4. **Process kill / SSH drop** is best-effort on BusyBox; locked account still blocks new logins.
5. **Local audit file** is not tamper-evident — documented as operational only.
6. **Device SDK builds** for 24.10/25.12 ARM+x86_64 not executed in this workspace — host smoke + layout validation done; see `docs/supported-releases.md` and `scripts/smoke-host.sh`.

## Tests run

```text
./scripts/smoke-host.sh
  shellcheck: ok
  package layout: ok
  validators / audit / list / non-root deny: ALL TESTS PASSED
```

## Recommendation

Accept for **0.1.0 prototype / field trial** on hardened lab images after first SDK install smoke. Address residual #1/#2 in integration tests on device (read-only ACL cannot call write methods; HTTPS-only management).
