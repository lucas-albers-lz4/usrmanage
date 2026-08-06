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

if "$BIN" audit --json --last abc 2>/dev/null; then
	bad "non-numeric --last accepted"
else
	ok "non-numeric --last rejected"
fi

if "$BIN" add nobody --role readonly --password-fd abc --json 2>/dev/null; then
	bad "non-numeric --password-fd accepted"
else
	ok "non-numeric --password-fd rejected"
fi

if "$BIN" show 'x;y' --json 2>/dev/null; then
	bad "injection username accepted on show"
else
	ok "injection username rejected on show"
fi

# JSON denial shape for --json (Zen MCR M8 / LuCI notifications)
out=$("$BIN" show 'x;y' --json 2>/dev/null) || true
echo "$out" | grep -q '"ok":false' && ok "show denial ok:false" || bad "show denial json: $out"
echo "$out" | grep -q '"error":"invalid_username"' && ok "show denial error token" || bad "show denial error: $out"

out=$("$BIN" add 'BadName' --role readonly --password-fd 0 --json 2>/dev/null) || true
echo "$out" | grep -q '"ok":false' && ok "add denial ok:false" || bad "add denial json: $out"
echo "$out" | grep -q '"error":"' && ok "add denial has error field" || bad "add denial error field: $out"

# Wheel del must rewrite /etc/group and verify membership
printf 'root:x:0:\nwheel:x:10:ops,audit\n' > "$USRMANAGE_GROUP"
um_wheel_del_user ops || bad "wheel_del ops"
um_in_wheel ops && bad "ops still in wheel" || ok "ops removed from wheel"
grep -q '^wheel:x:10:audit$' "$USRMANAGE_GROUP" && ok "wheel members rewritten" || bad "wheel members: $(cat "$USRMANAGE_GROUP")"

um_ensure_dirs
_mode=$(stat -c '%a' "$USRMANAGE_AUDIT_DIR" 2>/dev/null || stat -f '%OLp' "$USRMANAGE_AUDIT_DIR")
case "$_mode" in
	750|0750) ok "audit dir mode 750" ;;
	*) bad "audit dir mode $_mode (want 750)" ;;
esac

if [ "$(id -u)" != "0" ]; then
	out=$("$BIN" add evil --role readonly --json 2>/dev/null) || true
	echo "$out" | grep -q '"ok":false' && ok "non-root add json ok:false" || bad "non-root add json: $out"
	echo "$out" | grep -q '"error":"manage commands require root"' && ok "non-root add error detail" || bad "non-root add error: $out"
fi

[ "$fail" = "0" ] || exit 1
echo "ALL TESTS PASSED"
