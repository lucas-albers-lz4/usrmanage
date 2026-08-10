# Threat model — usrmanage

## Assets

| Asset | Sensitivity | Notes |
|-------|-------------|--------|
| `/etc/shadow` password hashes | Critical | Never returned by API or audit |
| `/etc/passwd`, `/etc/group` | High | Mutated only via account tools |
| `/etc/sudoers.d/usrmanage` | Critical | `%wheel` → full root (intentional) |
| `/etc/usrmanage/users` registry | High | Defines managed set / last-admin |
| `/var/log/usrmanage/audit.log` | Medium | Operational audit; root can alter |
| LuCI session + ubus password fields | Critical | TLS required in hardened deploys |

## Actors

- **Manage LuCI session** — read+write ACL on `luci-app-usrmanage`
- **View LuCI session** — read ACL only
- **Root CLI operator**
- **SSH readonly managed user** — no sudo; CLI view-only
- **Compromised non-wheel user**
- **Compromised root / full device compromise** — out of TCB; can rewrite audit

## Trust boundaries

Browser → HTTPS → uhttpd/rpcd → `usrmanage` CLI → passwd/group/shadow tools.

Passwords may traverse ubus JSON once (platform limitation) then are piped to CLI via `--password-fd` (never argv). Prefer HTTPS end-to-end.

## Abuse cases

| Case | Mitigation |
|------|------------|
| Shell metacharacters in username | Strict charset validation before any exec |
| Password in `ps` / argv | `--password-fd` / stdin only |
| Multi-line / control-char password silently truncated | Explicit `password_policy:multi_line` / `control_char` rejection in the CLI fd path and the rpcd pipe; account hash untouched |
| `USRMANAGE_*` env override redirects account files to arbitrary paths | Overrides are **inert unless `USRMANAGE_TEST_OVERRIDES=1`** (test-only gate, #72 / #65); production forces packaged defaults |
| Delete last managed admin | Count managed wheel members; deny |
| View→manage escalation | Split rpcd ACL; server enforces write |
| Mutate unmanaged/foreign users | Registry gate on mutators |
| Concurrent corrupt registry | `flock` exclusive lock |
| Incomplete remove after crash | `incomplete` marker + `doctor` |
| Audit claimed as compliance evidence | Documented as operational only |
| CSRF / session replay | LuCI/rpcd platform responsibility |

## Hard invariants

- **Never grant `usrmanage` via a NOPASSWD sudoers rule.** `%wheel ALL=(ALL:ALL) ALL` requires a password by design; removing that requirement would let a compromised wheel member run `usrmanage` as root unattended and, together with any environment they control, rewrite account files.
- **`USRMANAGE_TEST_OVERRIDES=1` is test-only.** It must not be set by production init scripts, uhttpd/rpcd, or sudoers environment overrides. Without it the `USRMANAGE_*` path overrides are ignored.

## Out of scope threats

- RADIUS/LDAP compromise
- Cryptographic integrity of local audit file
- SELinux/AppArmor MAC
- Attacker with root already on device


## Shadow-free stock images

Prefer shadow-utils when present. When absent, usrmanage edits account files directly under flock + snapshot restore. Concurrent non-usrmanage editors are out of scope (same as stock `useradd`).
