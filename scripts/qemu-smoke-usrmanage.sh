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

# Ensure account tools exist (pulled by package deps after 0.1.1; install if missing).
if ! ssh_guest 'command -v useradd >/dev/null 2>&1'; then
	echo "→ installing shadow account tools (guest missing useradd)" >&2
	if ssh_guest 'command -v apk >/dev/null 2>&1'; then
		ssh_guest 'apk add shadow-useradd shadow-userdel shadow-usermod shadow-chpasswd shadow-gpasswd' \
			|| die "could not install shadow-* account tools (apk)"
	else
		ssh_guest 'opkg install shadow-useradd shadow-userdel shadow-usermod shadow-chpasswd shadow-gpasswd' \
			|| die "could not install shadow-* account tools (opkg)"
	fi
fi

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

ssh_guest 'id umsmoke >/dev/null' || die "system user umsmoke missing"
if ssh_guest 'id -nG umsmoke | tr " " "\n" | grep -qx wheel'; then
	die "readonly user unexpectedly in wheel"
fi
ok "readonly not in wheel"

ssh_guest 'usrmanage show umsmoke --json' | grep -q umsmoke || die "show failed"
ok "show umsmoke"

ssh_guest 'usrmanage set-role umsmoke admin' || die "set-role admin failed"
ssh_guest 'id -nG umsmoke | tr " " "\n" | grep -qx wheel' || die "admin not in wheel"
ok "set-role admin → wheel"

ssh_guest 'printf "LabPass2!\n" | usrmanage passwd umsmoke --password-fd 0' \
	|| die "passwd failed"
ok "passwd"

ssh_guest 'usrmanage set-role umsmoke readonly' || die "set-role readonly failed"
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
