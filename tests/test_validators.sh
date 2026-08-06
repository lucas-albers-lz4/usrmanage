#!/bin/sh
# Unit tests for usrmanage validators and audit (no root / no real useradd required)
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"
BIN="$ROOT/openwrt-feed/usrmanage/files/usr/sbin/usrmanage"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export USRMANAGE_ETC="$TMP/etc"
export USRMANAGE_REGISTRY="$TMP/etc/users"
export USRMANAGE_AUDIT_DIR="$TMP/log"
export USRMANAGE_AUDIT="$TMP/log/audit.log"
export USRMANAGE_LOCK="$TMP/lock/usrmanage.lock"
export USRMANAGE_INCOMPLETE="$TMP/etc/incomplete"
export USRMANAGE_PASSWD="$TMP/passwd"
export USRMANAGE_SHADOW="$TMP/shadow"
export USRMANAGE_GROUP="$TMP/group"
export USRMANAGE_SUDOERS="$TMP/sudoers"
export USRMANAGE_DRY_RUN=1

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\naudit:x:1001:1001:audit:/home/audit:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\nops:::0:99999:7:::\naudit:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\naudit\n' > "$USRMANAGE_REGISTRY"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"

# shellcheck disable=SC1090
. "$LIB"

fail=0

ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

um_validate_username ops && ok "username ops" || bad "username ops"
um_validate_username audit_user && ok "username audit_user" || bad "username audit_user"
um_validate_username 'ops;rm' && bad "injection username allowed" || ok "injection username rejected"
um_validate_username root && bad "root allowed" || ok "root rejected"
um_validate_username 'ab cd' && bad "space allowed" || ok "space rejected"
um_validate_role admin && ok "role admin" || bad "role admin"
um_validate_role readonly && ok "role readonly" || bad "role readonly"
um_validate_role root && bad "bad role allowed" || ok "bad role rejected"

um_validate_password ops 'short' && bad "short pw allowed" || ok "short pw rejected"
um_validate_password ops 'ops' && bad "username pw allowed" || ok "username pw rejected"
um_validate_password ops 'goodpass1' && ok "good password" || bad "good password"

um_is_managed ops && ok "ops managed" || bad "ops managed"
um_is_managed nobody && bad "nobody managed" || ok "unmanaged"
_ac=$(um_count_managed_admins)
[ "$_ac" = "1" ] && ok "managed admin count" || bad "admin count $_ac"

um_audit grant testhost ok "" readonly
grep -q 'grant user=testhost' "$USRMANAGE_AUDIT" && ok "audit write" || bad "audit write"

chmod +x "$BIN"
"$BIN" --help >/dev/null
out=$("$BIN" list --json)
echo "$out" | grep -q '"name":"ops"' && ok "list --json" || bad "list json: $out"

out=$("$BIN" audit --json --last 10)
echo "$out" | grep -q '"events"' && ok "audit --json" || bad "audit json"

if "$BIN" show 'x;y' --json 2>/dev/null; then
	bad "injection username accepted on show"
else
	ok "injection username rejected on show"
fi

if [ "$(id -u)" != "0" ]; then
	if "$BIN" add evil --role readonly --json 2>/dev/null; then
		bad "non-root add allowed"
	else
		ok "non-root add denied"
	fi
fi

[ "$fail" = "0" ] || exit 1
echo "ALL TESTS PASSED"
