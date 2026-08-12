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

ssh_guest 'usrmanage del umrev' || die "del umrev failed"
ok "del umrev"

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
