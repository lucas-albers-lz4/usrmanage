# Readonly observer — appendix (ACL matrix & evidence)

Sections moved verbatim from [readonly-observer-luci.md](readonly-observer-luci.md); original numbers preserved for cross-references.

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

**Accepted residual (#156):** package-scoped `uci get` / `uci changes` via `luci-app-usrmanage-diagnostic-rpc` over network-config packages (`network` / `wireless` / `dhcp` / `firewall` / `system`) can expose wireless PSKs and related UCI secrets. That residual is intentional for stock Network diagnostic pages. Health replies still omit SSID/BSSID/keys; `luci-base` file list and `getWirelessDevices` stay denied. See §12.

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

## 7. ACL matrix detail

### 7.1 Session ACL (both roles need a shell)

Keep `luci-app-usrmanage-session` **narrower** than today:

- ubus: `session.access`, `luci.getFeatures` only.
- **No** `uci get/changes` on the **session** group (hostname from `health`). Page RPCs live on `luci-app-usrmanage-diagnostic-rpc`. Lab: still deny `luci-base` and `getWirelessDevices`; `uci get`/`changes` are allowed for diagnostic.

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

## 9. Lifecycle (must preserve)

Existing invariants: marker `usrmanage=1`, `$p$user`, registry membership, refuse foreign, tx + flock, session revoke on disable / delete / passwd / set-role.

**New**

| Event | ACL action | Sessions |
|-------|------------|----------|
| enable readonly | write diagnostic 9-set reads (session, health, app, diagnostic-rpc, status-{index,routes,realtime}, network-{config,diagnostics}), no writes | n/a |
| enable admin | write **full** scope (`read *` / `write *`, role-locked) | n/a |
| set-role admin→readonly | **rewrite ACL first** (drop `*` / app writes → health), then revoke, drop wheel, **revoke again**; fail closed if a live SID remains | **lab-class**, including racing `session.login` |
| set-role readonly→admin | write **full** scope (`*`, role-locked); revoke | revoke |
| disable / del / passwd | unchanged | revoke |
| doctor | **read-only** forever; never rewrite ACL / never grant `*` | — |
| package upgrade | rewrite readonly owned logins to diagnostic 9-set; migrate admin owned logins to role-derived full scope (`read *` / `write *`) | revoke only users whose lists actually changed |

Upgrade **must not** widen admin web privilege. Admin is role-locked to full scope (`*`); `--scope` is rejected. Release notes are not a control. `doctor --fix` must not exist on the read `doctor` method.

## 11. Tests

**Host (`smoke-host.sh`)**

- Expected reads/writes per role; readonly rejects `*` and `luci-base`.
- Health JSON **schema equality** (exact keys/types), plus MAC/IPv4/IPv6/hash regex over the whole reply. Fixture dumps include PSK/SSID. Deny-list grep is **not** proof.
- `health` takes no params; hostile JSON body is byte-identical. Declared **read**; health group has no `write` key; no `*`/`?` in method names.
- Readonly expected reads = diagnostic 9-set (session, health, app, diagnostic-rpc, status-{index,routes,realtime}, network-{config,diagnostics}).

**Lab (qemu-smoke, proof class `lab`)**

- Readonly `session.access` **deny** config-level `uci read` openvpn (non-diagnostic), `uci write` wireless/network, `luci-rpc.getWirelessDevices`, `luci-base` (file list of `/`); `file.read` `/etc/shadow`; `usrmanage.add` (mutators); `log.read`. **Allow** the diagnostic 9-set reads including `luci-app-usrmanage-diagnostic-rpc` (`network.interface` `dump`, `uci` `get`/`changes`, `luci-rpc` getBoardJSON/getHostHints/getNetworkDevices — **not** getWirelessDevices). Package-scoped wireless UCI read via network-config remains a documented residual for stock Network pages (#156).
- Readonly `usrmanage.health` allow; schema match; no ssid/key/MAC.
- Admin **full** can `uci get wireless`; demote then racing login cannot; leftover SID dead.
- Menu: readonly receives the diagnostic Status/Network views (`luci-mod-status-index` probe allowed; `session.access` on those five ACL names), no Full LuCI menus.

DRY_RUN stubs are **not** proof of lab denies ([security-review.md](../security-review.md)).

## 12. Threats this spec accepts or rejects

| Abuse | Disposition |
|-------|-------------|
| Readonly crafts ubus to `uci get wireless` / `getHostHints` | Accept residual for diagnostic stock pages (#156): `uci get`/`changes` via diagnostic-rpc over network-config packages (`network`/`wireless`/`dhcp`/`firewall`/`system`) plus `getHostHints` lease/neighbor hints; still no `luci-base` file list / getWirelessDevices |
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
| ACL matrix vs “split ACL” contradiction ships user enum | Readonly reads = diagnostic 9-set (session, health, app read, diagnostic-rpc, status-*, network-*); view-only UM included |
| Health deny-list grep is not a schema | Frozen key set, primitive types, no pass-through, `health` takes **no** params |
| Demote + I3 + `*` is full-root TOCTOU | Rewrite ACL **before** revoke; revoke twice; lab race |
| “No secrets” is false if the same account has a shell | Guarantee is **LuCI/ubus only** unless we later add nologin; document SSH residual |
| Session ACL `uci get/changes` may leak pending wireless | Prefer **no uci** on session ACL; lab plant `uci changes wireless` |
| `*` matcher currently rejects all `*` (ash word-split) | Role-gate `*`; never unquoted glob; exact set equality for readonly |
| Menu hide ≠ authorization | Lab `ubus call usrmanage list` deny |
| Hidden/non-canonical `config login` + `*` (Luna D4 / #108 class) | `--scope` picker removed (role-locked). Invisible `*` must not survive disable/demote |
| Upgrade rewrite without tx (Grok D8) | Readonly ACL rewrite only in luci-app postinst via `um_luci_login_ours_index` + flock/`um_tx_*`; never unmarked/`root` sections |

**Still open after round 1:** nologin for LuCI-enabled readonly; hostname / `assoc_count` privacy defaults; rpcd `uci changes` package filtering on 24.10/25.12 (must be lab-proven, not assumed). (Enumerated admin groups vs `*` resolved: admin is role-locked to full.)
