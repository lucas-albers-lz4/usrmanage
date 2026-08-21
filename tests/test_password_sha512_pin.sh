#!/bin/sh
# Host tests for issue #148: the preferred chpasswd path must pin sha512.
# BusyBox chpasswd hashes with the build-time default algo (may be md5/des),
# so um_password_write verifies the stored shadow hash is $6$ after the write,
# falls back to the pinned `passwd -a sha512` path otherwise, and fails loudly
# if a weak hash still survives. Discriminating: with the fix reverted (the
# chpasswd path returning without verification) the weak-hash cases below
# return 0 and these assertions fail.
#
# Hermetic: PATH shims stub chpasswd/passwd (env-selected hash), USRMANAGE_*
# overrides redirect every write into TMP; /usr/sbin is off PATH so no real
# system account tool can run. Passwords travel on stdin only and are never
# logged; the stub argv log is grepped to prove it.
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
export USRMANAGE_DRY_RUN=0
# Hermetic tests rely on USRMANAGE_* path overrides; enable the test-only gate.
export USRMANAGE_TEST_OVERRIDES=1

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$TMP/bin" "$TMP/bin2"

reset_shadow() {
	printf 'root:::0:99999:7:::\nops:!::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
	chmod 0600 "$USRMANAGE_SHADOW"
}
printf 'root:x:0:0:root:/root:/bin/sh\nops:x:1002:1002:ops:/home/ops:/bin/sh\n' > "$USRMANAGE_PASSWD"
printf 'root:x:0:\nwheel:x:10:\n' > "$USRMANAGE_GROUP"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT" "$USRMANAGE_SUDOERS"
reset_shadow

# chpasswd shim: writes CHPASSWD_STUB_HASH as the user's shadow hash — models
# an image whose CONFIG_FEATURE_DEFAULT_PASSWD_ALGO is not sha512 (#148).
# Logs argv (never stdin content) so the test can prove no password on argv.
cat > "$TMP/bin/chpasswd" <<'CHP'
#!/bin/sh
{
	printf 'argc=%s\n' "$#"
	i=1
	for a in "$@"; do
		printf 'arg%d=%s\n' "$i" "$a"
		i=$((i + 1))
	done
} > "${CHPASSWD_STUB_LOG:?}"
IFS= read -r line || exit 1
u=${line%%:*}
_tmp=$(mktemp)
awk -F: -v u="$u" -v h="${CHPASSWD_STUB_HASH:-\$1\$md5sal\$weakhash}" \
	'BEGIN{OFS=":"} $1==u{$2=h} {print}' "$USRMANAGE_SHADOW" > "$_tmp" || exit 1
if grep -q "^${u}:" "$_tmp"; then
	mv "$_tmp" "$USRMANAGE_SHADOW"
else
	rm -f "$_tmp"
	printf '%s:%s:0:99999:7:::\n' "$u" "$h" >> "$USRMANAGE_SHADOW" || exit 1
fi
chmod 0600 "$USRMANAGE_SHADOW" 2>/dev/null || true
exit 0
CHP

# passwd shim: models busybox `passwd -a sha512 <user>` ($3 = user). Writes
# PASSWD_STUB_HASH and drops a marker so the test can see the fallback ran.
cat > "$TMP/bin/passwd" <<'PWP'
#!/bin/sh
_u=$3
[ -n "$_u" ] || exit 1
printf 'invoked args=%s %s %s\n' "$1" "$2" "$3" >> "${PASSWD_STUB_LOG:?}"
if [ "${PASSWD_STUB_FAIL:-0}" = "1" ]; then
	# models a broken/missing busybox passwd (CodeRabbit r4 fold)
	exit 1
fi
_tmp=$(mktemp)
awk -F: -v u="$_u" -v h="${PASSWD_STUB_HASH:-\$6\$fbsal\$fixedhash}" \
	'BEGIN{OFS=":"} $1==u{$2=h} {print}' "$USRMANAGE_SHADOW" > "$_tmp" || exit 1
if grep -q "^${_u}:" "$_tmp"; then
	mv "$_tmp" "$USRMANAGE_SHADOW"
else
	rm -f "$_tmp"
	printf '%s:%s:0:99999:7:::\n' "$_u" "$h" >> "$USRMANAGE_SHADOW" || exit 1
fi
chmod 0600 "$USRMANAGE_SHADOW" 2>/dev/null || true
exit 0
PWP

chmod +x "$TMP/bin/chpasswd" "$TMP/bin/passwd"
# bin2 has NO chpasswd (models images without the applet) but keeps the passwd
# shim — the fallback path still needs it; assert the chpasswd absence below.
cp "$TMP/bin/passwd" "$TMP/bin2/passwd"
chmod +x "$TMP/bin2/passwd"

export PATH="$TMP/bin:/usr/bin:/bin"
export CHPASSWD_STUB_LOG="$TMP/chpasswd.log"
export PASSWD_STUB_LOG="$TMP/passwd.log"

# shellcheck disable=SC1090
. "$LIB"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

shadow_hash() {
	awk -F: -v u="$1" '$1==u{print $2}' "$USRMANAGE_SHADOW" 2>/dev/null
}

# --- normal path: chpasswd writes $6$ → accepted, no fallback ---
export CHPASSWD_STUB_HASH='$6$saltA$goodhash'
: > "$CHPASSWD_STUB_LOG"
rm -f "$PASSWD_STUB_LOG"
reset_shadow
if um_password_write ops 'FixPass148x' 2>/dev/null; then
	ok "chpasswd \$6\$ write accepted"
else
	bad "chpasswd \$6\$ write rejected"
fi
[ "$(shadow_hash ops)" = '$6$saltA$goodhash' ] && ok "normal path hash intact" \
	|| bad "normal path hash: $(shadow_hash ops)"
[ ! -f "$PASSWD_STUB_LOG" ] && ok "\$6\$ chpasswd does not fall back" \
	|| bad "unexpected fallback on \$6\$ chpasswd: $(cat "$PASSWD_STUB_LOG")"

# --- weak chpasswd hash ($1$ md5-style) → fallback pins $6$ ---
export CHPASSWD_STUB_HASH='$1$md5sal$weakhash'
export PASSWD_STUB_HASH='$6$fbsal$fixedhash'
: > "$CHPASSWD_STUB_LOG"
rm -f "$PASSWD_STUB_LOG"
reset_shadow
if um_password_write ops 'FixPass148y' 2>/dev/null; then
	ok "weak chpasswd hash triggers fallback (rc 0)"
else
	bad "weak chpasswd hash: write failed instead of falling back"
fi
case "$(shadow_hash ops)" in
	'$6$'*) ok "weak hash replaced by \$6\$ after fallback" ;;
	*) bad "weak hash survived: $(shadow_hash ops)" ;;
esac
[ -f "$PASSWD_STUB_LOG" ] && ok "pinned passwd path invoked on weak hash" \
	|| bad "fallback did not invoke passwd -a sha512"
grep -q 'args=-a sha512 ops' "$PASSWD_STUB_LOG" && ok "fallback pins -a sha512" \
	|| bad "fallback argv: $(cat "$PASSWD_STUB_LOG")"

# --- both paths weak → fail loudly, never accept the weak hash ---
export PASSWD_STUB_HASH='$1$still$weakhash'
reset_shadow
if um_password_write ops 'FixPass148z' 2>/dev/null; then
	bad "double-weak write returned 0 (weak hash silently accepted)"
else
	ok "unverifiable hash fails loudly"
fi
case "$(shadow_hash ops)" in
	'$6$'*) bad "double-weak left \$6\$? $(shadow_hash ops)" ;;
	*) ok "no \$6\$ claim after double-weak failure" ;;
esac

# --- password must never reach argv of either account tool ---
# Every password used in this file is searched, so a future regression that
# puts the password on argv (chpasswd currently takes NO args; passwd only
# takes -a sha512 <user>) fails here.
if grep -qE 'FixPass148[xytwvz]' "$CHPASSWD_STUB_LOG" "$PASSWD_STUB_LOG" 2>/dev/null; then
	bad "password leaked into tool argv logs"
else
	ok "password absent from chpasswd/passwd argv"
fi

# --- fallback-only environment (no chpasswd applet): same discipline ---
export PATH="$TMP/bin2:/usr/bin:/bin"
if command -v chpasswd >/dev/null 2>&1; then
	bad "bin2 PATH unexpectedly resolves chpasswd"
else
	ok "bin2 PATH hides chpasswd"
fi
export PASSWD_STUB_HASH='$6$fbsal$fixedhash'
reset_shadow
if um_password_write ops 'FixPass148w' 2>/dev/null; then
	ok "no-chpasswd \$6\$ write accepted"
else
	bad "no-chpasswd \$6\$ write rejected"
fi
case "$(shadow_hash ops)" in
	'$6$'*) ok "no-chpasswd path stores \$6\$" ;;
	*) bad "no-chpasswd hash: $(shadow_hash ops)" ;;
esac
export PASSWD_STUB_HASH='$1$badpw$weakhash'
reset_shadow
if um_password_write ops 'FixPass148v' 2>/dev/null; then
	bad "no-chpasswd weak write returned 0"
else
	ok "no-chpasswd weak write fails loudly"
fi
case "$(shadow_hash ops)" in
	'$6$'*) bad "no-chpasswd weak left \$6\$: $(shadow_hash ops)" ;;
	*) ok "no-chpasswd weak hash not accepted" ;;
esac

# --- tx rollback (#152 fold): a failed mutator write must restore the
# pre-change shadow, never leave a half-applied (weak-hash) password. ---
printf 'ops\n' > "$USRMANAGE_REGISTRY"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
export CHPASSWD_STUB_HASH='$1$md5sal$weakhash'
export PASSWD_STUB_HASH='$1$still$weakhash'
reset_shadow
_orig=$(shadow_hash ops)
: > "$USRMANAGE_AUDIT"
if printf 'FixPass148t\n' | um_with_lock um_mut_passwd ops 0 2>/dev/null; then
	bad "tx-rollback: um_mut_passwd succeeded despite unverifiable hash"
else
	ok "tx-rollback: um_mut_passwd fails loudly"
fi
case "$(shadow_hash ops)" in
	"$_orig") ok "tx-rollback: shadow restored to pre-change state" ;;
	*) bad "tx-rollback: shadow NOT restored (got $(shadow_hash ops), orig $_orig)" ;;
esac
# rc=2 path (CodeRabbit r2 fold): the failure must be audited as
# password_hash_unverified (denied) — NOT a policy failure, which had already
# passed before the write.
grep -q 'result=denied reason=password_hash_unverified' "$USRMANAGE_AUDIT" \
	&& ok "tx-rollback: audit records denied password_hash_unverified" \
	|| bad "tx-rollback: audit missing denied hash reason: $(cat "$USRMANAGE_AUDIT" 2>/dev/null)"

# --- passwd TOOL failure (CodeRabbit r4 fold): a broken/missing passwd must
# NOT be mislabeled password_hash_unverified — tool failures return rc=1 and
# the mutator keeps the legacy fail audit.
export CHPASSWD_STUB_HASH='$1$md5sal$weakhash'
export PASSWD_STUB_FAIL=1
printf 'ops\n' > "$USRMANAGE_REGISTRY"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
reset_shadow
if um_password_write ops 'FixPass148w' 2>/dev/null; then
	bad "passwd-fail: write returned 0"
else
	_rc=$?
	[ "$_rc" = "1" ] && ok "passwd-fail: rc=1 (tool failure, not unverified)" || bad "passwd-fail: rc=$_rc (want 1)"
fi
: > "$USRMANAGE_AUDIT"
printf 'FixPass148t\n' | um_with_lock um_mut_passwd ops 0 2>/dev/null || true
if grep -q 'password_hash_unverified' "$USRMANAGE_AUDIT"; then
	bad "passwd-fail: wrongly audited password_hash_unverified: $(cat "$USRMANAGE_AUDIT")"
else
	ok "passwd-fail: no unverified audit on tool failure"
fi
unset PASSWD_STUB_FAIL

[ "$fail" = "0" ] || { echo "sha512-pin tests FAILED" >&2; exit 1; }
echo "PASSWORD SHA512 PIN TESTS PASSED"
