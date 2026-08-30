# Design: readonly owned LuCI = observer (health, no secrets)

Status: **in-PR / implemented in 0.1.7** (LuCI + docs; backend ACL/rpcd/cli on same branch). Product-lock change vs pre-0.1.7 usrmanage-only owned logins.

Adversarial pass (2026-08-19): grok, luna, opus — **do not ship revision 1**. Consensus locks are in the [appendix](readonly-observer-luci-appendix.md#16-review-round-1-consensus).

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

1. Readonly + owned LuCI can show that the device is healthy without seeing secrets **in the web/ubus session**, and without changing configuration.
2. Admin + owned LuCI gets **Full LuCI** (keys, backups, all apps) — intentional; prefer HTTPS / management VLAN.
3. Secret classes (K1–K8, appendix) never appear in readonly ubus replies, menus, or HTML.
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
| Untrusted viewer | `readonly` | Customer/site contact troubleshoots with diagnostic menus (Overview/Routing/Realtime, Interfaces/Diagnostics, health) and **view-only** User Management. Cannot change configuration or mint users. Must not get Full LuCI / `luci-base` / mutator write. |
| Root CLI | root | Unchanged. |
| Foreign web login | (not owned) | `luci-app-acl` still supported; never adopted. |

<<<<<<< HEAD
## 5. Secret / leak classes (must not reach readonly)

Readonly owned sessions **must not** obtain any of:

| ID | Class | Typical source if we grant the wrong ACL |
|----|--------|------------------------------------------|
| K1 | Wireless PSK / SAE / WEP keys | `uci get wireless`, luci-mod-network, backups |
| K2 | SSID / mesh ID / BSSID strings | `iwinfo info`, `uci wireless`, `getWirelessDevices` |
| K3 | VPN / WG / IPSec / OpenVPN / OVPN / WireGuard private keys and PSKs | `uci` of those packages, luci-app-wireguard, backups |
| K4 | UNIX password hashes, `root` password, dropbear keys | `file read` `/etc/shadow`, luci-mod-system backup |
| K5 | Feed/opkg signing material, usrmanage secrets | file ACL, luci-app-opkg |
| K6 | Full UCI dump / configuration backup | `luci-base` file list + cgi-io backup |
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
=======
## 5. ACL matrix (owned logins)
>>>>>>> a91894c (docs(concise): trim readonly observer, archive incident docs, DRY install)

Constants (names are normative for tests):

- `USRMANAGE_SESSION_ACL` = `luci-app-usrmanage-session` (LuCI shell only).
- `USRMANAGE_HEALTH_ACL` = `luci-app-usrmanage-health` (`health` **only**; no `write` object in the JSON).
- `USRMANAGE_APP_ACL` = `luci-app-usrmanage` (read = list/show/audit/doctor/policy; write = mutators). Readonly diagnostic gets this group on **read only** (view-only UM).
- Scope is recorded as `option usrmanage_scope 'diagnostic'|'full'` and is **derived from UNIX role** (no picker). Legacy `app` → `diagnostic`.

| UNIX role | scope | `list read` | `list write` |
|-----------|-------|-------------|--------------|
| readonly | diagnostic | session, health, app, diagnostic-rpc, status-index, status-routes, status-realtime, network-config, network-diagnostics | *(empty)* |
| admin | full | `*` | `*` |

`um_luci_login_expected_reads` / `expected_writes` are **role-derived**. Tamper detection: exact set mismatch, `*`, or `luci-base` on readonly → `tampered`.

For the full ACL matrix (secret classes, stock-group denials, session/health ACL detail, lifecycle table) and test evidence, see [Appendix](readonly-observer-luci-appendix.md).

## 6. Admin `*`

`*` (`usrmanage_scope=full`) is **stronger than sudo** in one way: one `session.login` then backup/`uci`/`file.read` until timeout, with no per-op password. Prefer it only on HTTPS / management VLAN. Owned admin is **role-locked to full** scope (`*`); there is no `--scope` picker. Matcher: allow literal `*` **only** when role is admin **and** scope is full; never unquoted glob (`um_luci_login_acls_match_role` noglob-guards). Readonly exact set equality; extra names or `*` → `tampered`.

HTTPS / management VLAN guidance unchanged. Enabling LuCI still exposes the UNIX password to `session.login`.

Never put `*` on readonly. Parser must treat readonly + `*` as **tampered**.

## 7. UI

- Health page: stock LuCI classes, `_()` strings, no hardcoded hex (existing theme tests).
- Readonly: no mutator buttons, no policy editor, no user table. Health view imports only `view`/`rpc`/`ui`; whole-object `expect: { '': { … } }`; never `luci.network` / `iwinfo`.
- Admin full scope: Full LuCI (all menus).
- Banner copy: readonly web login is for **device health**, not account admin.

## Appendix

The detailed ACL rules, secret/leak classes, stock-group denial rationale, session/health ACL breakdown, lifecycle table, and test/review evidence live in [readonly-observer-luci-appendix.md](readonly-observer-luci-appendix.md).
