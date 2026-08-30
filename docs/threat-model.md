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
| Feed signing keys (`OPKG_FEED_SECRET_KEY`, `APK_FEED_SECRET_KEY`) | Critical | Whoever holds them can sign packages that install as root on every subscriber |
| Pages deploy key (`FEED_DEPLOY_KEY`) | High | Controls what the feed origin serves |

## Actors

- **Manage LuCI session** — write ACL on `luci-app-usrmanage` (admin app scope)
- **Full LuCI owned session** — admin with `--scope full` (`*` ACL; explicit opt-in)
- **Observer LuCI session** — readonly owned login; `health` ACL only (device health, no secrets over ubus)
- **View LuCI session (legacy)** — pre-0.1.7 readonly with app read ACL (removed in 0.1.7 upgrade rewrite)
- **Root CLI operator**
- **SSH readonly managed user** — no sudo; CLI view-only; same password as observer LuCI if enabled
- **Compromised non-wheel user**
- **Compromised root / full device compromise** — out of TCB; can rewrite audit
- **Publish job (`publish-packages`)** — holds the signing keys and the deploy key; anything that can inject shell into it, or that it fetches unpinned, is inside the release TCB
- **Feed origin (GitHub Pages)** — what a router trusts after `opkg-key add` / `/etc/apk/keys`

## Trust boundaries

Runtime: Browser → HTTPS → uhttpd/rpcd → `usrmanage` CLI → passwd/group/shadow tools.

Release: tag → `publish-packages` job (signing keys) → signed feed on Pages → router `opkg`/`apk`.

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
| Concurrent corrupt registry / account files | `flock` exclusive lock + multi-file tx snapshot/rollback (incl. rpcd, set-role) |
| Incomplete remove after crash | `incomplete` marker + `doctor` (+ keep snapdir on failed restore) |
| Audit claimed as compliance evidence | Documented as operational only |
| CSRF / session replay | LuCI/rpcd platform responsibility |
| Stuck mutator blocks all manage ops | BusyBox `flock` has no wait timeout — accepted; optional doctor diagnostics (candidate [#61](https://github.com/lucas-albers-lz4/usrmanage/issues/61) S2) |
| Wrong passwd/shadow line on `list --all` for exotic unmanaged names | Prefer fixed-string username lookup (`grep -F`); candidate [#61](https://github.com/lucas-albers-lz4/usrmanage/issues/61) S1 |
| Non-admin granted `usrmanage` via a NOPASSWD sudo rule | Out of the shipped configuration and explicitly forbidden — `USRMANAGE_*` path overrides would make it arbitrary root write ([#65](https://github.com/lucas-albers-lz4/usrmanage/issues/65) P1) |

## Supply-chain abuse cases

| Case | Mitigation |
|------|------------|
| Shell injected into the publish job via a workflow input | Pass inputs through `env:`, never interpolate into `run:` ([#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63) R1) |
| Signing key readable beyond the job that needs it | Written under `umask 077`, mode 0600; mode preservation through decode/normalize is [#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63) R2 |
| Secret key material published with the feed | Staging copies only public key material (`feed_publish_copy_keys`) |
| Compromised third-party action or build tool signs the feed | Pin actions, SDK images, and signing tooling by digest/commit ([#63](https://github.com/lucas-albers-lz4/usrmanage/issues/63) R3/R4) |
| Operator trusts a substituted feed key on first install | Key fingerprints published for out-of-band checking. Install snippets make sure that the SHA-256 matches before trust ([#64](https://github.com/lucas-albers-lz4/usrmanage/issues/64), fixed in [PR #81](https://github.com/lucas-albers-lz4/usrmanage/pull/81)) |

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

## Audit ledger

What was checked/fixed/accepted across reviews: [security-review.md](security-review.md).
