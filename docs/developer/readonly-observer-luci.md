# Design: readonly owned LuCI = observer (health, no secrets)

Status: **in-PR / implemented in 0.1.7** (LuCI + docs; backend ACL/rpcd/cli on same branch). Product-lock change vs pre-0.1.7 usrmanage-only owned logins.

Adversarial pass (2026-08-19): grok, luna, opus — **do not ship revision 1**. Consensus locks are in [§16](#16-review-round-1-consensus). Gemini Flash 3.5 was requested but is not an available agent model.

Related: [roles-and-acl.md](../user/roles-and-acl.md), [threat-model.md](../threat-model.md), [security.md](../security.md), [luci-ux.md](luci-ux.md).

## 1. Problem

Owned LuCI logins (`set-luci-login` / Add checkbox) grant a **fixed** rpcd ACL matrix:

| UNIX role | Today’s owned grants |
|-----------|----------------------|
| readonly | `read`: `luci-app-usrmanage-session`, `luci-app-usrmanage` |
| admin | same `read` + `write`: `luci-app-usrmanage` |

That matches **app** permissions, not **device** jobs:

- **IT staff** mint named local admins because the fleet has no RADIUS. Those people need to **run OpenWrt** (already true on SSH via `wheel`+sudo). Owned LuCI still cages them in User Management.
- **Readonly** is meant for an untrusted viewer (customer on an IT-managed CPE, roommate): “is the router working?” Viewing the usrmanage user table does not answer that, so the role is unused.

## 2. Decision

Keep **exactly two UNIX roles**: `admin` | `readonly`. Do not add an `observer` role name in CLI, registry, or LuCI.

Readonly **is** the observer profile: look, don’t touch, **don’t see secrets over LuCI/ubus**. Same UNIX password still allows SSH (nologin is a non-goal); that residual is documented, not “no secrets on the device.”

Admin **is** a named root on **SSH** (`wheel`+sudo). Owned LuCI is **role-locked**: admin → **Full LuCI** (`*`); readonly → **diagnostic** (curated Status/Network/health + view-only User Management). There is no `--scope` picker.

LuCI remains **opt-in** per managed user. Owned logins still use `$p$username` only. Foreign `luci-app-acl` principals stay untouched.

## 3. Goals / non-goals

**Goals**

1. Readonly + owned LuCI can confirm device health without seeing secrets **in the web/ubus session**, and without changing config.
2. Admin + owned LuCI gets **Full LuCI** (keys, backups, all apps) — intentional; prefer HTTPS / management VLAN.
3. Secret classes in §5 never appear in readonly ubus replies, menus, or HTML.
4. Demote/disable/delete still revoke sessions and rewrite owned ACL lists (existing lifecycle).
5. Host tests + lab (qemu-smoke) prove allow and **deny** (not only “page loads”).

**Non-goals**

- Third role, RADIUS, per-site ACL editors, custom `luci-app-acl` presets in the UI.
- Making SSH readonly a nologin account (shell without sudo stays).
- Cryptographic redaction of syslog (readonly simply must not get log ACL).
- Hiding topology from someone who already has L2 on the LAN (MAC/IP on the wire is out of scope).

## 4. Actors and stories

| Actor | UNIX | Story |
|-------|------|--------|
| IT operator | `admin` | Several named people with root **on SSH**. Create/revoke via usrmanage at scale. Web: Full LuCI when enabled. |
| Untrusted viewer | `readonly` | Customer/site contact troubleshoots with diagnostic menus (Overview/Routing/Realtime, Interfaces/Diagnostics, health) and **view-only** User Management. Cannot change config or mint users. Must not get Full LuCI / `luci-base` / mutator write. |
| Root CLI | root | Unchanged. |
| Foreign web login | (not owned) | `luci-app-acl` still supported; never adopted. |

## 5. Secret / leak classes (must not reach readonly)

Readonly owned sessions **must not** obtain any of:

| ID | Class | Typical source if we grant the wrong ACL |
|----|--------|------------------------------------------|
| K1 | Wireless PSK / SAE / WEP keys | `uci get wireless`, luci-mod-network, backups |
| K2 | SSID / mesh ID / BSSID strings | `iwinfo info`, `uci wireless`, `getWirelessDevices` |
| K3 | VPN / WG / IPSec / OpenVPN / OVPN / WireGuard private keys and PSKs | `uci` of those packages, luci-app-wireguard, backups |
| K4 | UNIX password hashes, `root` password, dropbear keys | `file read` `/etc/shadow`, luci-mod-system backup |
| K5 | Feed/opkg signing material, usrmanage secrets | file ACL, luci-app-opkg |
| K6 | Full UCI dump / config backup | `luci-base` file list + cgi-io backup |
| K7 | Syslog / dmesg (credentials, tokens, client IDs) | `luci-mod-status-logs` |
| K8 | usrmanage **write** (mint admins, passwd, policy) | `luci-app-usrmanage` write |

**Allowed (health):** board/model, hostname, OpenWrt release, uptime, load, memory/flash used (no mount secrets), WAN/LAN **carrier/up** and **address-family up** without dumping firewall rules, wifi **radio up/down + associated station count** with **no SSID/BSSID/keys**, optional **DHCP lease count** with **no** MAC/hostname/IP list.

DHCP client identifiers and wifi station MACs are **PII**. Default: **omit**. Do not grant `getDHCPLeases` or `iwinfo assoclist`.

## 6. Why not stock LuCI ACL groups

Granting `luci-mod-status-*` or `luci-base` to readonly fails closed on paper and open in practice:

| Stock group | Why forbidden for readonly |
|-------------|----------------------------|
| `luci-base` | `uci get`; filesystem `list` of `/`; **write** is full UCI |
| `luci-base-network-status` | `uci` read **`wireless`** (K1/K2) |
| `luci-mod-status-index` | includes **`uci` write `dhcp`** |
| `luci-mod-status-index-wifi` | **write** `hostapd.*` (`del_client`, WPS) |
| `luci-mod-status-logs` | K7 |
| `luci-mod-status-processes` write | `kill` |
| `*` | everything |

Readonly must **never** receive `*`, `luci-base`, or stock groups on the **write** list. Diagnostic grants selected stock status/network ACL **names on `list read` only** so Interfaces/Overview remain non-mutating (rpcd applies a group’s internal write block only when the group is on the login write list). Health redacted RPC remains for Device health. Logs/processes/`luci-base` stay forbidden.

**Product-lock change for admin:** enabling owned LuCI for admin **is** `read *` + `write *` (`usrmanage_scope=full`). Demote must drop `*` immediately (rewrite then revoke). Upgrade/sync rewrites legacy admin `app` → `full`.

## 7. ACL matrix (owned logins)

Constants (names are normative for tests):

- `USRMANAGE_SESSION_ACL` = `luci-app-usrmanage-session` (LuCI shell only).
- `USRMANAGE_HEALTH_ACL` = `luci-app-usrmanage-health` (`health` **only**; no `write` object in the JSON).
- `USRMANAGE_APP_ACL` = `luci-app-usrmanage` (read = list/show/audit/doctor/policy; write = mutators). Readonly diagnostic gets this group on **read only** (view-only UM).
- Scope is recorded as `option usrmanage_scope 'diagnostic'|'full'` and is **derived from UNIX role** (no picker). Legacy `app` → `diagnostic`.

| UNIX role | scope | `list read` | `list write` |
|-----------|-------|-------------|--------------|
| readonly | diagnostic | session, health, app, status-index, status-routes, status-realtime, network-config, network-diagnostics | *(empty)* |
| admin | full | `*` | `*` |

`um_luci_login_expected_reads` / `expected_writes` are **role-derived**. Tamper detection: exact set mismatch, `*`, or `luci-base` on readonly → `tampered`.

### 7.1 Session ACL (both roles need a shell)

Keep `luci-app-usrmanage-session` **narrower** than today:

- ubus: `session.access`, `luci.getFeatures` only.
- **No** `uci get/changes` on the session group. Hostname comes from `health`. Lab: plant pending `uci set wireless.…` and assert readonly `uci changes` / `uci get wireless` denied.

### 7.2 App ACL — new `health` method

Add ubus `usrmanage.health` (lock the name in the implementation PR; no `health*` glob). Zero parameters; ignore `read_input`. Hostile params → byte-identical reply. Errors: `{"ok":false,"error":"health_unavailable"}` only.

- ACL: **read** on `luci-app-usrmanage-health` only. Method list exactly `["health"]`. **No** `write` object in that JSON.
- **No** new write methods for readonly.
- Implementation in rpcd plugin: gather from `ubus call system board/info` and netifd as **root** (plugin already runs privileged), then **project** a fixed JSON allow-list. Never pass through `uci get` output, `iwinfo info`, or `network.wireless` blobs.

Example reply (illustrative):

```json
{
  "ok": true,
  "hostname": "cpe-12",
  "release": "24.10.x",
  "uptime_s": 86400,
  "load": [0.01, 0.02, 0.00],
  "wan": { "up": true, "ipv4": true, "ipv6": true },
  "lan": { "up": true },
  "wifi": { "radios_up": 2, "radios_total": 2, "assoc_count": 4 },
  "dhcp_lease_count": 6
}
```

Forbidden keys anywhere in the object or nested strings: `key`, `key2`, `sae_password`, `private_key`, `secret`, `ssid`, `mesh_id`, `bssid`, `mac`, `ipaddr` (client), `hostname` of leases, WG/VPN fields, `shadow`, file paths under `/etc`.

WAN/LAN `up` is boolean. Do **not** return WAN public IP in v1 (can identify the site); revisit only with an explicit story.

`assoc_count` / `dhcp_lease_count` are integers. No lists.

### 7.3 usrmanage view vs health view

| Session | Menus |
|---------|--------|
| readonly owned | **System → Device health** + view-only User Management (list/show/audit/doctor, no mutators). Status/Network diagnostic menus (Overview, Routing, Realtime, Interfaces, Diagnostics). |
| admin owned (app) | User Management only (today). |
| admin owned (full) | Full LuCI menu (`*` ACL). User Management remains. |

Readonly **CLI** (`usrmanage list` as non-root) stays view-only for accounts; that is SSH, not the web observer story.

Menu hide is cosmetic. ACL split is **mandatory**:

- `luci-app-usrmanage-health` — `health` only (readonly `list read`)
- `luci-app-usrmanage` — list/show/audit/doctor/policy + writes (admin `app` or via `*`)

Readonly can `usrmanage.list` / `audit` / `doctor` / `policy` (view-only) via the diagnostic app-read ACL. Mutators (`add`, `del`, `passwd`, `set-role`, policy writes) remain denied. Menu hide is cosmetic; lab deny of those write methods is the control.

## 8. Admin `*`

`*` (`usrmanage_scope=full`) is **stronger than sudo** in one way: one `session.login` then backup/`uci`/`file.read` until timeout, with no per-op password. Prefer it only on HTTPS / management VLAN. Owned admin is **role-locked to full** scope (`*`); there is no `--scope` picker. Matcher: allow literal `*` **only** when role is admin **and** scope is full; never unquoted glob (`um_luci_login_acls_match_role` noglob-guards). Readonly exact set equality; extra names or `*` → `tampered`.

HTTPS / management VLAN guidance unchanged. Enabling LuCI still exposes the UNIX password to `session.login`.

Never put `*` on readonly. Parser must treat readonly + `*` as **tampered**.

## 9. Lifecycle (must preserve)

Existing invariants: marker `usrmanage=1`, `$p$user`, registry membership, refuse foreign, tx + flock, session revoke on disable / delete / passwd / set-role.

**New**

| Event | ACL action | Sessions |
|-------|------------|----------|
| enable readonly | write diagnostic 8-set reads (session, health, app, status-{index,routes,realtime}, network-{config,diagnostics}), no writes | n/a |
| enable admin | write **full** scope (`read *` / `write *`, role-locked) | n/a |
| set-role admin→readonly | **rewrite ACL first** (drop `*` / app writes → health), then revoke, drop wheel, **revoke again**; fail closed if a live SID remains | **lab-class**, including racing `session.login` |
| set-role readonly→admin | write **full** scope (`*`, role-locked); revoke | revoke |
| disable / del / passwd | unchanged | revoke |
| doctor | **read-only** forever; never rewrite ACL / never grant `*` | — |
| package upgrade | rewrite readonly owned logins to diagnostic 8-set; migrate admin owned logins to role-derived full scope (`read *` / `write *`) | revoke only users whose lists actually changed |

Upgrade **must not** widen admin web privilege. Admin is role-locked to full scope (`*`); `--scope` is rejected. Release notes are not a control. `doctor --fix` must not exist on the read `doctor` method.

## 10. UI

- Health page: stock LuCI classes, `_()` strings, no hardcoded hex (existing theme tests).
- Readonly: no mutator buttons, no policy editor, no user table. Health view imports only `view`/`rpc`/`ui`; whole-object `expect: { '': { … } }`; never `luci.network` / `iwinfo`.
- Admin full scope: Full LuCI (all menus).
- Banner copy: readonly web login is for **device health**, not account admin.

## 11. Tests

**Host (`smoke-host.sh`)**

- Expected reads/writes per role; readonly rejects `*` and `luci-base`.
- Health JSON **schema equality** (exact keys/types), plus MAC/IPv4/IPv6/hash regex over the whole reply. Fixture dumps include PSK/SSID. Deny-list grep is **not** proof.
- `health` takes no params; hostile JSON body is byte-identical. Declared **read**; health group has no `write` key; no `*`/`?` in method names.
- Readonly expected reads = diagnostic 8-set (session, health, app, status-{index,routes,realtime}, network-{config,diagnostics}).

**Lab (qemu-smoke, proof class `lab`)**

- Readonly `session.access` **deny** config-level `uci read` openvpn (non-diagnostic), `uci write` wireless/network, `ubus uci get` (web-path method — no luci-base, K1); `file.read` `/etc/shadow`; `usrmanage.add` (mutators); `log.read`. **Allow** the diagnostic 8-set reads: `usrmanage.list` / `audit` / `doctor` / `policy` (view-only), `health`, config-level `uci read` wireless/network (via `luci-mod-network-config` read), and `session.access` on the five Status/Network ACLs (`luci-mod-status-{index,routes,realtime}`, `luci-mod-network-{config,diagnostics}`). Keep mutators and sensitive reads denied.
- Readonly `usrmanage.health` allow; schema match; no ssid/key/MAC.
- Admin **full** can `uci get wireless`; demote then racing login cannot; leftover SID dead.
- Menu: readonly receives the diagnostic Status/Network views (`luci-mod-status-index` probe allowed; `session.access` on those five ACL names), no Full LuCI menus.

DRY_RUN stubs are **not** proof of lab denies ([security-review.md](../security-review.md)).

## 12. Threats this spec accepts or rejects

| Abuse | Disposition |
|-------|-------------|
| Readonly crafts ubus to `uci get wireless` | Reject: no `luci-base` / wireless uci ACL; lab deny |
| Readonly uses stock Overview JS (SSID in DOM) | Reject: do not grant those menu ACLs; health is our view only |
| Plugin copies `iwinfo info` into health | Reject: frozen schema; unknown fields dropped |
| Admin `--scope full` `*` reads keys | Accept: explicit web-root opt-in (stronger than sudo: no per-op password) |
| Viewer sees lease MACs | Reject in v1 (no lease list) |
| Viewer sees WAN IP | Reject in v1 |
| Compromised readonly SSH user | Accept residual: same password is a UNIX login; K1–K7 via shell are **out of the LuCI guarantee** |
| Foreign ACL mixed with owned | Unchanged: refuse enable |
| Health method grows fields later | Require security-ledger update + lab denies for new keys |

## 13. Implementation sketch (not a license to skip §5)

1. ACL JSON: `luci-app-usrmanage-health` (mandatory split).
2. rpcd `health` + schema projector in lib (BusyBox ash, no passwords on argv).
3. `um_luci_login_expected_*` role- and **scope**-dependent; `usrmanage_scope`; never unquoted `*`.
4. LuCI view `system/usrmanage-health` + menu `depends.acl` = health group.
5. User Management menu: `depends.acl` stays `luci-app-usrmanage` (admin `*` still matches).
6. Docs: roles-and-acl, security.md product lock, threat-model actors, ROADMAP, AGENTS.md one-liner.
7. qemu-smoke ACL probes; ledger proof class `lab` for demote `*` → health.

## 14. Open questions (resolve in implementation PR)

1. Exact ubus name: **`health`** (locked).
2. Hostname on health (site identifier on CPE fleets). Default still **yes**; may omit later.
3. `assoc_count` occupancy side channel. Default **yes** as integer; consider buckets later.
4. Upgrade: auto-widen admin to `*` vs require explicit scope. **Locked: admin is role-locked to full scope (`*`); upgrade migrate rewrites legacy admin `app` → full, readonly → diagnostic** (§16).
5. Split ACL vs residual user enumeration. **Locked: split is mandatory** (§16).

## 15. Adversarial review

Independent reviews of **this document** (not a code diff). Findings are design-class (`D*`) until lab-proven. Ledger update belongs in the implementation PR ([security-review.md](../security-review.md)).

## 16. Review round 1 consensus

Models: grok, luna, opus (2026-08-19). All three: **do not ship revision 1**. Shared blockers and the locks applied in revision 2:

| Consensus | Lock in this spec |
|-----------|-------------------|
| Auto-`*` on upgrade / `doctor --fix` is a silent privilege widen | Admin role-locked to **full** scope (`*`); `--scope` picker removed; doctor stays read-only |
| §7 table vs “split ACL” contradiction ships user enum | Readonly reads = diagnostic 8-set (session, health, app read, status-*, network-*); view-only UM included |
| Health deny-list grep is not a schema | Frozen key set, primitive types, no pass-through, `health` takes **no** params |
| Demote + I3 + `*` is full-root TOCTOU | Rewrite ACL **before** revoke; revoke twice; lab race |
| “No secrets” is false if the same account has a shell | Guarantee is **LuCI/ubus only** unless we later add nologin; document SSH residual |
| Session ACL `uci get/changes` may leak pending wireless | Prefer **no uci** on session ACL; lab plant `uci changes wireless` |
| `*` matcher currently rejects all `*` (ash word-split) | Role-gate `*`; never unquoted glob; exact set equality for readonly |
| Menu hide ≠ authorization | Lab `ubus call usrmanage list` deny |
| Hidden/non-canonical `config login` + `*` (Luna D4 / #108 class) | `--scope` picker removed (role-locked). Invisible `*` must not survive disable/demote |
| Upgrade rewrite without tx (Grok D8) | Readonly ACL rewrite only in luci-app postinst via `um_luci_login_ours_index` + flock/`um_tx_*`; never unmarked/`root` sections |

**Still open after round 1:** nologin for LuCI-enabled readonly; hostname / `assoc_count` privacy defaults; rpcd `uci changes` package filtering on 24.10/25.12 (must be lab-proven, not assumed). (Enumerated admin groups vs `*` resolved: admin is role-locked to full.)
