#!/bin/sh
# Host tests for password policy presets (openwrt / standard / strict).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"

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
export USRMANAGE_SRC=cli
export USRMANAGE_ACTOR=testhost
export USRMANAGE_TEST_OVERRIDES=1
export USRMANAGE_DRY_RUN=1

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$TMP/bin" "$TMP/uci"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:$6$salt$hash:0:99999:7:::\nops:$6$salt$ophash:0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\n' > "$USRMANAGE_REGISTRY"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"
chmod 0440 "$USRMANAGE_SUDOERS"

# Hermetic uci: key=value store for usrmanage.policy.*
cat > "$TMP/bin/uci" <<'UCI'
#!/bin/sh
store="${TMP:?}/uci/store"
mkdir -p "$(dirname "$store")"
touch "$store"
while [ "$1" = "-q" ]; do shift; done
case "$1" in
	get)
		key=$2
		awk -F= -v k="$key" '$1==k { print substr($0, index($0,"=")+1); exit }' "$store"
		;;
	set)
		pair=$2
		key=${pair%%=*}
		val=${pair#*=}
		# Section type assign (usrmanage.policy=usrmanage) — ignore value shape.
		_tmp=$(mktemp)
		awk -F= -v k="$key" -v v="$val" '
			$1==k { next }
			{ print }
			END { print k "=" v }
		' "$store" > "$_tmp" && mv "$_tmp" "$store"
		;;
	commit) ;;
	changes) ;;
	*) exit 0 ;;
esac
UCI
chmod +x "$TMP/bin/uci"
export PATH="$TMP/bin:$PATH"
export TMP

# shellcheck disable=SC1090
. "$LIB"
. "$ROOT/tests/lib.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# Factory default
um_policy_load
[ "$UM_POL_PRESET" = "openwrt" ] && ok "default preset openwrt" || bad "default preset=$UM_POL_PRESET"
[ "$UM_POL_MIN_LENGTH" = "8" ] && ok "default min_length 8" || bad "default min=$UM_POL_MIN_LENGTH"

# Named presets: apply → save → load round-trip
# cell: name:min:lower:upper:digit:special
for _cell in 'standard:10:1:1:1:0' 'strict:12:1:1:1:1' 'openwrt:8:0:0:0:0'; do
	_p=${_cell%%:*}
	_rest=${_cell#*:}
	_min=${_rest%%:*}
	_rest=${_rest#*:}
	_lo=${_rest%%:*}
	_rest=${_rest#*:}
	_up=${_rest%%:*}
	_rest=${_rest#*:}
	_di=${_rest%%:*}
	_sp=${_rest#*:}
	um_policy_apply_preset_values "$_p" || bad "apply $_p"
	um_with_lock um_policy_save || bad "save $_p"
	um_policy_load
	[ "$UM_POL_PRESET" = "$_p" ] && ok "preset $_p round-trip" || bad "preset $_p got $UM_POL_PRESET"
	[ "$UM_POL_MIN_LENGTH" = "$_min" ] && ok "preset $_p min_length $_min" \
		|| bad "preset $_p min=$UM_POL_MIN_LENGTH want $_min"
	[ "$UM_POL_REQUIRE_LOWER" = "$_lo" ] && [ "$UM_POL_REQUIRE_UPPER" = "$_up" ] \
		&& [ "$UM_POL_REQUIRE_DIGIT" = "$_di" ] && [ "$UM_POL_REQUIRE_SPECIAL" = "$_sp" ] \
		&& ok "preset $_p toggles" \
		|| bad "preset $_p toggles lo=$UM_POL_REQUIRE_LOWER up=$UM_POL_REQUIRE_UPPER di=$UM_POL_REQUIRE_DIGIT sp=$UM_POL_REQUIRE_SPECIAL"
	[ "$(um_policy_label "$_p")" = "$(echo "$_p" | awk '{print toupper(substr($0,1,1)) substr($0,2)}' | sed 's/openwrt/OpenWrt/;s/standard/Standard/;s/strict/Strict/')" ] \
		|| true
	case "$_p" in
		openwrt) [ "$(um_policy_label "$_p")" = "OpenWrt" ] && ok "label OpenWrt" || bad "label $(um_policy_label "$_p")" ;;
		standard) [ "$(um_policy_label "$_p")" = "Standard" ] && ok "label Standard" || bad "label $(um_policy_label "$_p")" ;;
		strict) [ "$(um_policy_label "$_p")" = "Strict" ] && ok "label Strict" || bad "label $(um_policy_label "$_p")" ;;
	esac
done

# um_policy_set_fields custom → detect
um_policy_set_fields custom 14 1 1 1 1 0 || bad "set_fields custom"
[ "$UM_POL_PRESET" = "custom" ] && ok "custom detects as custom" || bad "custom got $UM_POL_PRESET"
[ "$UM_POL_MIN_LENGTH" = "14" ] && ok "custom min_length 14" || bad "custom min=$UM_POL_MIN_LENGTH"

# Password gate under strict
um_policy_apply_preset_values strict
if printf 'Short1!\n' | um_password_capture_fd ops 0 2>"$TMP/pol.err"; then
	bad "strict should reject Short1!"
else
	ok "strict rejects short password"
fi
[ -n "${UM_POL_FAIL_REASON:-}" ] && ok "strict fail reason=$UM_POL_FAIL_REASON" \
	|| ok "strict rejection (reason optional)"

if printf 'StrictPass12!\n' | um_password_capture_fd ops 0 2>"$TMP/pol2.err"; then
	ok "strict accepts matching password"
else
	bad "strict rejected good password: reason=${UM_POL_FAIL_REASON:-} $(cat "$TMP/pol2.err")"
fi

# Restore openwrt
um_policy_apply_preset_values openwrt
um_with_lock um_policy_save
um_policy_load
[ "$UM_POL_PRESET" = "openwrt" ] && ok "restored openwrt" || bad "restore got $UM_POL_PRESET"

if [ "$fail" -ne 0 ]; then
	echo "test_policy: FAILED" >&2
	exit 1
fi
echo "test_policy: ok"
