#!/usr/bin/env bash
# Headless smoke test for usrmanage on a running QEMU guest.
#
#   ./scripts/qemu-smoke-usrmanage.sh
set -euo pipefail

HOST="${OPENWRT_HOST:-127.0.0.1}"
PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -p "$PORT")

die() { echo "smoke FAIL: $*" >&2; exit 1; }
ok() { echo "smoke OK: $*"; }

ssh_guest() {
	ssh "${SSH_OPTS[@]}" "root@${HOST}" "$@"
}

echo "== usrmanage QEMU smoke (root@${HOST}:${PORT}) ==" >&2

ssh_guest 'echo connected' >/dev/null 2>&1 \
	|| die "SSH unreachable"

RELEASE="$(ssh_guest '. /etc/openwrt_release 2>/dev/null; echo "${DISTRIB_RELEASE:-unknown}"')"
ARCH="$(ssh_guest 'uname -m')"
ok "guest ${ARCH} OpenWrt ${RELEASE}"

ssh_guest 'command -v usrmanage >/dev/null' || die "usrmanage binary missing"
ok "usrmanage installed"

# Stock images use busybox fallbacks — do not install shadow-* here.

ssh_guest 'rm -f /etc/usrmanage/incomplete'
ssh_guest 'usrmanage doctor' >/dev/null || die "usrmanage doctor failed"
ok "usrmanage doctor"

ssh_guest 'usrmanage list --json' >/dev/null || die "usrmanage list failed"
ok "usrmanage list"

# Keep one admin so del of secondary users is allowed (last-admin guard).
ssh_guest 'printf "LabPassAdmin!\n" | usrmanage add umadmin --role admin --password-fd 0' \
	|| die "usrmanage add admin failed"
ok "add umadmin admin"

ssh_guest 'printf "LabPass1!\n" | usrmanage add umsmoke --role readonly --password-fd 0' \
	|| die "usrmanage add readonly failed"
ok "add umsmoke readonly"

# Aging fields: min=0 max=99999 after create+passwd (shadow-free path).
_aging="$(ssh_guest 'awk -F: -v u=umsmoke '\''$1==u{print $4,$5}'\'' /etc/shadow')"
[[ "$_aging" == "0 99999" ]] || die "umsmoke aging want '0 99999' got '${_aging}'"
ok "umsmoke aging min/max after add"

ssh_guest 'id umsmoke >/dev/null' || die "system user umsmoke missing"
if ssh_guest 'id -nG umsmoke | tr " " "\n" | grep -qx wheel'; then
	die "readonly user unexpectedly in wheel"
fi
ok "readonly not in wheel"

ssh_guest 'usrmanage show umsmoke --json' | grep -q umsmoke || die "show failed"
ok "show umsmoke"

ssh_guest 'usrmanage set-role umsmoke --role admin' || die "set-role admin failed"
ssh_guest 'id -nG umsmoke | tr " " "\n" | grep -qx wheel' || die "admin not in wheel"
ok "set-role admin → wheel"

ssh_guest 'printf "LabPass2!\n" | usrmanage passwd umsmoke --password-fd 0' \
	|| die "passwd failed"
ok "passwd"

_aging="$(ssh_guest 'awk -F: -v u=umsmoke '\''$1==u{print $4,$5}'\'' /etc/shadow')"
[[ "$_aging" == "0 99999" ]] || die "umsmoke aging after passwd want '0 99999' got '${_aging}'"
ok "umsmoke aging min/max after passwd"

ssh_guest 'usrmanage set-role umsmoke --role readonly' || die "set-role readonly failed"
ok "set-role back to readonly"

ssh_guest 'usrmanage audit --last 20' | grep -q umsmoke || die "audit missing umsmoke events"
ok "audit log"

ssh_guest 'usrmanage del umsmoke' || die "del umsmoke failed"
ssh_guest '! id umsmoke >/dev/null 2>&1' || die "user still present after del"
ok "del umsmoke"

# last-admin must refuse deleting the sole remaining managed admin
if ssh_guest 'usrmanage del umadmin' 2>/dev/null; then
	die "del umadmin should have failed (last_admin)"
fi
ok "last-admin guard blocks del umadmin"

# Live ubus session revoke (issue #95) — lab-only; passwords never logged.
# Requires set-luci-login + ubus session login on the guest.
ssh_guest 'usrmanage del umrev >/dev/null 2>&1 || true'
ssh_guest 'printf "LabRevoke1!\n" | usrmanage add umrev --role readonly --password-fd 0' \
	|| die "add umrev failed"
ok "add umrev for session revoke"
ssh_guest 'usrmanage set-luci-login umrev --enable' \
	|| die "set-luci-login umrev --enable failed"
ok "umrev luci login enabled"

_login_json="$(ssh_guest 'ubus call session login "{\"username\":\"umrev\",\"password\":\"LabRevoke1!\"}"')" \
	|| die "session login as umrev failed"
_sid="$(printf '%s' "$_login_json" | grep -oE '"ubus_rpc_session":[[:space:]]*"[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')"
[[ -n "$_sid" ]] || die "no session id from login"
ok "umrev session created (${_sid:0:8}…)"

_field_probe="$(ssh_guest "G=\$(ubus call session get \"{\\\"ubus_rpc_session\\\":\\\"${_sid}\\\"}\") || exit 1
V=\$(printf '%s' \"\$G\" | jsonfilter -e '@.values.username' 2>/dev/null || true)
D=\$(printf '%s' \"\$G\" | jsonfilter -e '@.data.username' 2>/dev/null || true)
printf 'values=%s data=%s\n' \"\$V\" \"\$D\"")" || die "session get before revoke failed"
_values_user="$(printf '%s' "$_field_probe" | sed -n 's/^values=\(.*\) data=.*/\1/p')"
_data_user="$(printf '%s' "$_field_probe" | sed -n 's/^values=.* data=\(.*\)/\1/p')"
if [[ -n "$_values_user" ]]; then
	ok "session get username via @.values.username=${_values_user}"
elif [[ -n "$_data_user" ]]; then
	ok "session get username via @.data.username=${_data_user}"
else
	die "session get has neither @.values.username nor @.data.username (probe: ${_field_probe})"
fi
_matched="${_values_user:-$_data_user}"
[[ "$_matched" == "umrev" ]] || die "session username mismatch (got '${_matched}')"

ssh_guest 'usrmanage set-luci-login umrev --disable' \
	|| die "set-luci-login umrev --disable failed"
ok "umrev luci login disabled (revoke path)"

if ssh_guest "ubus call session get \"{\\\"ubus_rpc_session\\\":\\\"${_sid}\\\"}\"" >/dev/null 2>&1; then
	die "session ${_sid:0:8}… still alive after disable"
fi
ok "umrev session destroyed after disable"

# P1 (#107): after disable, a *new* session.login as that user must fail.
if ssh_guest 'ubus call session login "{\"username\":\"umrev\",\"password\":\"LabRevoke1!\"}"' >/dev/null 2>&1; then
	die "post-disable session.login as umrev succeeded (login must be denied)"
fi
ok "post-disable session.login denied (P1)"

ssh_guest 'usrmanage del umrev' || die "del umrev failed"
ok "del umrev"

# P2 (#107): demote admin→readonly with owned LuCI login; new login has no write
# on luci-app-usrmanage (access-group write probe).
ssh_guest 'usrmanage del umdemote >/dev/null 2>&1 || true'
ssh_guest 'printf "LabDemote1!\n" | usrmanage add umdemote --role admin --password-fd 0' \
	|| die "add umdemote failed"
ok "add umdemote admin for demote ACL probe"
ssh_guest 'usrmanage set-luci-login umdemote --enable' \
	|| die "set-luci-login umdemote --enable failed"
ok "umdemote luci login enabled"

_admin_login="$(ssh_guest 'ubus call session login "{\"username\":\"umdemote\",\"password\":\"LabDemote1!\"}"')" \
	|| die "admin session login as umdemote failed"
_admin_sid="$(printf '%s' "$_admin_login" | grep -oE '"ubus_rpc_session":[[:space:]]*"[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')"
[[ -n "$_admin_sid" ]] || die "no admin session id"
# Pre-demote: require an explicit write grant so P2 cannot false-green.
_admin_write="$(ssh_guest "ubus call session access \"{\\\"ubus_rpc_session\\\":\\\"${_admin_sid}\\\",\\\"scope\\\":\\\"access-group\\\",\\\"object\\\":\\\"luci-app-usrmanage\\\",\\\"function\\\":\\\"write\\\"}\"")" \
	|| die "admin session access probe failed"
if printf '%s' "$_admin_write" | grep -qiE '"access"[[:space:]]*:[[:space:]]*false'; then
	die "admin session lacks luci-app-usrmanage write before demote (got: ${_admin_write})"
fi
if ! printf '%s' "$_admin_write" | grep -qiE '"access"[[:space:]]*:[[:space:]]*true|"write"[[:space:]]*:[[:space:]]*true|^true$'; then
	die "admin write grant not confirmed before demote (got: ${_admin_write})"
fi
ok "umdemote admin has luci-app-usrmanage write before demote"

ssh_guest 'usrmanage set-role umdemote --role readonly' \
	|| die "demote umdemote failed"
ok "umdemote demoted to readonly"

# Prior admin SID must be destroyed by demote revoke.
if ssh_guest "ubus call session get \"{\\\"ubus_rpc_session\\\":\\\"${_admin_sid}\\\"}\"" >/dev/null 2>&1; then
	die "admin session still alive after demote"
fi
ok "umdemote admin session destroyed after demote"

_ro_login="$(ssh_guest 'ubus call session login "{\"username\":\"umdemote\",\"password\":\"LabDemote1!\"}"')" \
	|| die "readonly re-login as umdemote failed"
_ro_sid="$(printf '%s' "$_ro_login" | grep -oE '"ubus_rpc_session":[[:space:]]*"[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')"
[[ -n "$_ro_sid" ]] || die "no readonly session id"
_ro_write="$(ssh_guest "ubus call session access \"{\\\"ubus_rpc_session\\\":\\\"${_ro_sid}\\\",\\\"scope\\\":\\\"access-group\\\",\\\"object\\\":\\\"luci-app-usrmanage\\\",\\\"function\\\":\\\"write\\\"}\"")" \
	|| die "readonly session access probe failed"
# Explicit deny required — empty/failed output must not count as pass.
if printf '%s' "$_ro_write" | grep -qiE '"access"[[:space:]]*:[[:space:]]*true|"write"[[:space:]]*:[[:space:]]*true|^true$'; then
	die "readonly session still has luci-app-usrmanage write (got: ${_ro_write})"
fi
if ! printf '%s' "$_ro_write" | grep -qiE '"access"[[:space:]]*:[[:space:]]*false'; then
	die "readonly write deny not confirmed (got: ${_ro_write})"
fi
ok "demote drops luci-app-usrmanage write on re-login (P2)"

ssh_guest 'usrmanage set-luci-login umdemote --disable' || true
ssh_guest 'usrmanage del umdemote' || die "del umdemote failed"
ok "del umdemote"

# Readonly diagnostic observer + admin full ACL probes. Passwords stay on
# the guest command line only (lab fixture residual); never printed here.
_sid_access() {
	# _sid_access <sid> <scope> <object> <function>
	ssh_guest "ubus call session access \"{\\\"ubus_rpc_session\\\":\\\"$1\\\",\\\"scope\\\":\\\"$2\\\",\\\"object\\\":\\\"$3\\\",\\\"function\\\":\\\"$4\\\"}\""
}

_assert_denied() {
	_body=$1
	_what=$2
	if printf '%s' "$_body" | grep -qiE '"access"[[:space:]]*:[[:space:]]*true'; then
		die "expected deny for ${_what} (got: ${_body})"
	fi
	if ! printf '%s' "$_body" | grep -qiE '"access"[[:space:]]*:[[:space:]]*false'; then
		die "deny not confirmed for ${_what} (got: ${_body})"
	fi
}

_assert_allowed() {
	_body=$1
	_what=$2
	if printf '%s' "$_body" | grep -qiE '"access"[[:space:]]*:[[:space:]]*false'; then
		die "expected allow for ${_what} (got: ${_body})"
	fi
	if ! printf '%s' "$_body" | grep -qiE '"access"[[:space:]]*:[[:space:]]*true'; then
		die "allow not confirmed for ${_what} (got: ${_body})"
	fi
}

ssh_guest 'usrmanage del umobs >/dev/null 2>&1 || true'
ssh_guest 'printf "LabObs1!\n" | usrmanage add umobs --role readonly --password-fd 0' \
	|| die "add umobs failed"
ssh_guest 'usrmanage set-luci-login umobs --enable' \
	|| die "set-luci-login umobs --enable failed"
ok "umobs readonly luci login enabled"

_obs_login="$(ssh_guest 'ubus call session login "{\"username\":\"umobs\",\"password\":\"LabObs1!\"}"')" \
	|| die "session login as umobs failed"
_obs_sid="$(printf '%s' "$_obs_login" | grep -oE '"ubus_rpc_session":[[:space:]]*"[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')"
[[ -n "$_obs_sid" ]] || die "no umobs session id"

_assert_denied "$(_sid_access "$_obs_sid" file /etc/shadow read)" "readonly file.read /etc/shadow"
_assert_denied "$(_sid_access "$_obs_sid" ubus usrmanage add)" "readonly usrmanage.add"
_assert_denied "$(_sid_access "$_obs_sid" ubus log read)" "readonly log.read"
_assert_denied "$(_sid_access "$_obs_sid" uci openvpn get)" "readonly uci openvpn get"
# Diagnostic grants luci-mod-network-config on READ → uci get wireless/network/firewall allowed.
_assert_allowed "$(_sid_access "$_obs_sid" uci wireless get)" "readonly diagnostic uci wireless get"
_assert_allowed "$(_sid_access "$_obs_sid" uci network get)" "readonly diagnostic uci network get"
_assert_denied "$(_sid_access "$_obs_sid" uci wireless set)" "readonly diagnostic uci wireless set"
_assert_denied "$(_sid_access "$_obs_sid" uci network set)" "readonly diagnostic uci network set"
_assert_allowed "$(_sid_access "$_obs_sid" access-group luci-mod-status-index read)" "readonly diagnostic luci-mod-status-index"
_assert_allowed "$(_sid_access "$_obs_sid" ubus usrmanage list)" "readonly usrmanage.list (view-only)"
_assert_allowed "$(_sid_access "$_obs_sid" ubus usrmanage health)" "readonly usrmanage.health"
ok "readonly diagnostic: view list/health/status; deny add/logs/shadow/openvpn"

_h="$(ssh_guest "ubus call usrmanage health \"{\\\"ubus_rpc_session\\\":\\\"${_obs_sid}\\\"}\"")" \
	|| die "readonly usrmanage.health call failed"
printf '%s' "$_h" | grep -q '"ok"' || die "health reply missing ok (got: ${_h})"
printf '%s' "$_h" | grep -qiE 'ssid|sae_password|private_key|"key"|mesh_id|bssid' \
	&& die "health reply contains secret class token"
printf '%s' "$_h" | grep -qE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' \
	&& die "health reply contains MAC"
ok "readonly health reply has no ssid/key/MAC"

# HTTP /ubus: view list allowed; mutator add denied.
_obs_list="$(curl -sS -H 'Content-Type: application/json' \
	-d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"${_obs_sid}\",\"usrmanage\",\"list\",{}]}" \
	"http://${HOST}:${HTTP_PORT}/ubus" 2>/dev/null || true)"
if ! printf '%s' "$_obs_list" | grep -q '"result"'; then
	die "readonly usrmanage.list not allowed over HTTP /ubus (got: ${_obs_list})"
fi
_obs_add="$(curl -sS -H 'Content-Type: application/json' \
	-d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"${_obs_sid}\",\"usrmanage\",\"add\",{}]}" \
	"http://${HOST}:${HTTP_PORT}/ubus" 2>/dev/null || true)"
if ! printf '%s' "$_obs_add" | grep -q '"Access denied"'; then
	die "readonly usrmanage.add not denied over HTTP /ubus (got: ${_obs_add})"
fi
# Positive control on the same path: health must be allowed for the observer.
_obs_allow="$(curl -sS -H 'Content-Type: application/json' \
	-d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"call\",\"params\":[\"${_obs_sid}\",\"usrmanage\",\"health\",{}]}" \
	"http://${HOST}:${HTTP_PORT}/ubus" 2>/dev/null || true)"
if ! printf '%s' "$_obs_allow" | grep -q '"result"'; then
	die "readonly usrmanage.health not allowed over HTTP /ubus (got: ${_obs_allow})"
fi
ok "readonly usrmanage.list denied + health allowed over HTTP /ubus"

ssh_guest 'usrmanage set-luci-login umobs --disable' || true
ssh_guest 'usrmanage del umobs' || die "del umobs failed"
ok "del umobs"

# Admin full (role-locked, no --scope): can uci get wireless; demote → diagnostic.
# Second admin so last_admin does not abort the demote of umfull below.
ssh_guest 'usrmanage del umkeep >/dev/null 2>&1 || true'
printf 'LabKeep1!\n' | ssh_guest 'usrmanage add umkeep --role admin --password-fd 0' \
	|| die "add umkeep failed"
ok "add umkeep (second admin for umfull demote)"

ssh_guest 'usrmanage del umfull >/dev/null 2>&1 || true'
ssh_guest 'printf "LabFull1!\n" | usrmanage add umfull --role admin --password-fd 0' \
	|| die "add umfull failed"
ssh_guest 'usrmanage set-luci-login umfull --enable' \
	|| die "set-luci-login umfull --enable failed"
ok "umfull admin luci login enabled (role-locked full)"

# --scope is rejected with luci_scope_role_locked in role-locked model
_scope_err="$(ssh_guest 'usrmanage set-luci-login umfull --enable --scope full 2>&1 || true')"
printf '%s' "$_scope_err" | grep -q 'luci_scope_role_locked' \
	|| die "--scope should be rejected with luci_scope_role_locked (got: ${_scope_err})"
ok "--scope rejected: luci_scope_role_locked"

_full_login="$(ssh_guest 'ubus call session login "{\"username\":\"umfull\",\"password\":\"LabFull1!\"}"')" \
	|| die "session login as umfull failed"
_full_sid="$(printf '%s' "$_full_login" | grep -oE '"ubus_rpc_session":[[:space:]]*"[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')"
[[ -n "$_full_sid" ]] || die "no umfull session id"
_assert_allowed "$(_sid_access "$_full_sid" ubus uci get)" "admin full ubus uci.get"
ok "admin full can uci.get (role-locked full)"

# Demote full → diagnostic: leftover SID dead; new session has diagnostic ACLs.
ssh_guest 'usrmanage set-role umfull --role readonly' || die "demote umfull failed"
ok "umfull demoted to readonly"
if ssh_guest "ubus call session get \"{\\\"ubus_rpc_session\\\":\\\"${_full_sid}\\\"}\"" >/dev/null 2>&1; then
	die "admin-full session still alive after demote"
fi
ok "umfull leftover SID dead after demote"

_full_re="$(ssh_guest 'ubus call session login "{\"username\":\"umfull\",\"password\":\"LabFull1!\"}"')" \
	|| die "re-login as demoted umfull failed"
_full_re_sid="$(printf '%s' "$_full_re" | grep -oE '"ubus_rpc_session":[[:space:]]*"[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')"
# diagnostic: write paths denied; health still allowed; usrmanage add denied
_assert_denied "$(_sid_access "$_full_re_sid" ubus usrmanage add)" "demoted full usrmanage.add"
_assert_allowed "$(_sid_access "$_full_re_sid" ubus usrmanage health)" "demoted full usrmanage.health"
ok "demote from full → diagnostic: add denied, health allowed"

ssh_guest 'usrmanage set-luci-login umfull --disable' || true
ssh_guest 'usrmanage del umfull' || die "del umfull failed"
ok "del umfull"

ssh_guest 'usrmanage del umkeep' || die "del umkeep failed"
ok "del umkeep"

# LuCI assets + ubus
ssh_guest 'test -f /www/luci-static/resources/view/system/usrmanage.js' \
	|| die "missing LuCI view JS"
ok "LuCI view asset"

ssh_guest 'test -f /usr/share/luci/menu.d/luci-app-usrmanage.json' \
	|| die "missing menu.d"
ok "LuCI menu.d"

ssh_guest 'ubus -v list usrmanage' >/dev/null \
	|| die "ubus object usrmanage missing (rpcd plugin?)"
ok "ubus usrmanage object"

ssh_guest 'ubus call usrmanage list' >/dev/null \
	|| die "ubus usrmanage list failed"
ok "ubus usrmanage list"

ssh_guest 'ubus call usrmanage doctor' >/dev/null \
	|| die "ubus usrmanage doctor failed"
ok "ubus usrmanage doctor"

COOKIE_JAR="$(mktemp)"
cleanup_cookies() { rm -f "$COOKIE_JAR"; }
trap cleanup_cookies EXIT
curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" \
	-d 'luci_username=root&luci_password=' \
	"http://${HOST}:${HTTP_PORT}/cgi-bin/luci" >/dev/null 2>&1 || true
HTTP_HEADERS="$(curl -sS -c "$COOKIE_JAR" -b "$COOKIE_JAR" -D - -o /dev/null \
	"http://${HOST}:${HTTP_PORT}/cgi-bin/luci/admin/system/usrmanage" 2>/dev/null || true)"
HTTP_CODE="$(printf '%s' "$HTTP_HEADERS" | awk 'toupper($1) ~ /^HTTP/ { print $2; exit }')"
if [[ -z "$HTTP_CODE" ]]; then
	die "LuCI page unreachable"
fi
case "$HTTP_CODE" in
	200|302|303) ok "LuCI usrmanage page HTTP ${HTTP_CODE}" ;;
	*) die "LuCI usrmanage page HTTP ${HTTP_CODE}" ;;
esac

echo "== usrmanage QEMU smoke PASSED ==" >&2
