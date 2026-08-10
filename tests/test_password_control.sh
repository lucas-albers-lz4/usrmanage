#!/bin/sh
# Host tests for issue #72 P2: multi-line / control-character passwords are
# rejected with an EXPLICIT error through the real --password-fd path, and the
# account hash stays unchanged. Valid single-line passwords are unaffected.
#
# The lib-level cases run as any user (hermetic: no real /etc/* writes — a fake
# `passwd` on PATH absorbs the write path). The rpcd cases exercise the real
# rpcd->CLI pipeline and require root (um_require_root); they are skipped when
# non-root so CI stays green.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"
CLI="$ROOT/openwrt-feed/usrmanage/files/usr/sbin/usrmanage"
RPCD="$ROOT/openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage"

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
export USRMANAGE_DRY_RUN=0
# Hermetic tests rely on USRMANAGE_* path overrides; enable the test-only gate.
export USRMANAGE_TEST_OVERRIDES=1

# Fake passwd: absorbs the real write path so DRY_RUN=0 tests stay hermetic.
# Called as `passwd -a sha512 <user>`; writes a marker hash into the overridden
# shadow instead of touching the host system.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/passwd" <<'FAKE'
#!/bin/sh
_u=$3
[ -n "$_u" ] || exit 1
_tmp="${USRMANAGE_SHADOW}.pw.$$"
awk -F: -v OFS=: -v u="$_u" '
	$1 == u { $2 = "$6$testmark$fakehash" }
	{ print }
' "$USRMANAGE_SHADOW" > "$_tmp" && mv "$_tmp" "$USRMANAGE_SHADOW"
chmod 0600 "$USRMANAGE_SHADOW"
exit 0
FAKE
chmod +x "$TMP/bin/passwd"
# Exclude /usr/sbin so chpasswd/useradd never see a real system tool on PATH.
export PATH="$TMP/bin:/usr/bin:/bin"

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
printf 'root:x:0:0:root:/root:/bin/sh\nops:x:1002:1002:ops:/home/ops:/bin/sh\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\nops:$6$before$hash:0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\n' > "$USRMANAGE_REGISTRY"

# shellcheck disable=SC1090
. "$LIB"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

shadow_hash() {
	awk -F: -v u=ops '$1==u{print $2}' "$USRMANAGE_SHADOW" 2>/dev/null
}

# --- functional: real --password-fd path, embedded newline ---
_orig=$(shadow_hash)
_err=$TMP/i1.err
if printf 'SecretPass1\nBadPass2\n' | um_with_lock um_mut_passwd ops 0 2>"$_err"; then
	bad "embedded newline accepted"
else
	ok "embedded newline rejected"
fi
grep -q 'password_policy:multi_line' "$_err" && ok "multi-line error token" || bad "multi-line err: $(cat "$_err")"
[ "$(shadow_hash)" = "$_orig" ] && ok "hash unchanged after embedded newline" || bad "hash changed after embedded newline"

# --- functional: real --password-fd path, tab (control char) ---
_orig=$(shadow_hash)
_err=$TMP/i2.err
if printf 'Secret\tPass1\n' | um_with_lock um_mut_passwd ops 0 2>"$_err"; then
	bad "tab password accepted"
else
	ok "tab password rejected"
fi
grep -q 'password_policy:control_char' "$_err" && ok "control_char error token" || bad "control_char err: $(cat "$_err")"
[ "$(shadow_hash)" = "$_orig" ] && ok "hash unchanged after tab password" || bad "hash changed after tab password"

# --- functional: trailing newline inside the value is still multi-line ---
_orig=$(shadow_hash)
_err=$TMP/i3.err
if printf 'SecretPass1\n\n' | um_with_lock um_mut_passwd ops 0 2>"$_err"; then
	bad "trailing-newline password accepted"
else
	ok "trailing-newline password rejected"
fi
grep -q 'password_policy:multi_line' "$_err" && ok "trailing newline multi_line token" || bad "trailing nl err: $(cat "$_err")"
[ "$(shadow_hash)" = "$_orig" ] && ok "hash unchanged after trailing newline" || bad "hash changed after trailing newline"

# --- valid password unaffected: DRY_RUN short-circuit (no false reject) ---
export USRMANAGE_DRY_RUN=1
_orig=$(shadow_hash)
if printf 'SecretPass1\n' | um_with_lock um_mut_passwd ops 0 2>"$TMP/v1.err"; then
	ok "valid password accepted via fd (DRY_RUN)"
else
	bad "valid password falsely rejected: $(cat "$TMP/v1.err")"
fi
[ "$(shadow_hash)" = "$_orig" ] && ok "DRY_RUN left hash unchanged" || bad "DRY_RUN wrote hash"

# --- valid password unaffected: full real write path (DRY_RUN=0, fake passwd) ---
export USRMANAGE_DRY_RUN=0
if printf 'SecretPass1\n' | um_with_lock um_mut_passwd ops 0 2>"$TMP/v2.err"; then
	ok "valid password accepted via fd (real write path)"
else
	bad "valid password failed write path: $(cat "$TMP/v2.err")"
fi
grep -q '\$6\$testmark\$fakehash' "$USRMANAGE_SHADOW" && ok "valid password hash written" || bad "valid password hash not written"

# --- rpcd -> real CLI pipeline (root only) ---
if [ "$(id -u)" = "0" ]; then
	# Reset the account hash so the rpcd assertions below are meaningful.
	printf 'root:::0:99999:7:::\nops:$6$before$hash:0:99999:7:::\n' > "$USRMANAGE_SHADOW"
	chmod 0600 "$USRMANAGE_SHADOW"

	# jsonfilter mock that decodes \n / \t so rpcd sees real control chars.
	cat > "$TMP/bin/jsonfilter" <<'JF'
#!/bin/sh
e=
while [ $# -gt 0 ]; do
	case "$1" in
		-e) e=$2; shift 2 ;;
		*) shift ;;
	esac
done
key=${e#@.}
inp=$(cat)
val=$(printf '%s' "$inp" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1)
printf '%b' "$val"
JF
	chmod +x "$TMP/bin/jsonfilter"
	export USRMANAGE_BIN="$CLI"

	_orig=$(shadow_hash)
	_out=$(sh "$RPCD" call passwd '{"name":"ops","password":"NewSecret1\nBadPass2"}' 2>/dev/null) || true
	echo "$_out" | grep -q '"ok":false' && ok "rpcd embedded newline ok:false" || bad "rpcd nl json: $_out"
	echo "$_out" | grep -q 'password_control_chars' && ok "rpcd control error token" || bad "rpcd nl error: $_out"
	[ "$(shadow_hash)" = "$_orig" ] && ok "rpcd hash unchanged after newline" || bad "rpcd hash changed after newline"

	_orig=$(shadow_hash)
	_out=$(sh "$RPCD" call passwd '{"name":"ops","password":"New\tSecret1"}' 2>/dev/null) || true
	echo "$_out" | grep -q '"ok":false' && ok "rpcd tab ok:false" || bad "rpcd tab json: $_out"
	echo "$_out" | grep -q 'password_control_chars' && ok "rpcd tab control error token" || bad "rpcd tab error: $_out"
	[ "$(shadow_hash)" = "$_orig" ] && ok "rpcd hash unchanged after tab" || bad "rpcd hash changed after tab"

	# rpcd must not over-reject a clean single-line password.
	_orig=$(shadow_hash)
	_out=$(sh "$RPCD" call passwd '{"name":"ops","password":"NewSecret1"}' 2>/dev/null) || true
	echo "$_out" | grep -q '"ok":true' && ok "rpcd clean password accepted" || bad "rpcd clean pw json: $_out"
	grep -q '\$6\$testmark\$fakehash' "$USRMANAGE_SHADOW" && ok "rpcd clean password hash written" || bad "rpcd clean pw hash not written"
	[ "$(shadow_hash)" != "$_orig" ] && ok "rpcd clean password hash changed" || bad "rpcd clean pw hash unchanged"
else
	echo "skip: rpcd->CLI pipeline test (needs root; CI runs non-root)"
fi

[ "$fail" = "0" ] || exit 1
echo "PASSWORD CONTROL TESTS PASSED"
