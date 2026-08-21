#!/bin/sh
# Host happy-path mutator flows: add → set-role → passwd → demote → del.
# Mirrors the LuCI product tour without touching a live guest (DRY_RUN / stubs).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export USRMANAGE_LIB_DIR=$(dirname "$LIB")
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
export USRMANAGE_RPCD_CONFIG="$TMP/rpcd"
export USRMANAGE_HOME_ROOT="$TMP/home"
export USRMANAGE_SRC=cli
export USRMANAGE_ACTOR=testhost
export USRMANAGE_TEST_OVERRIDES=1
export USRMANAGE_DRY_RUN=1
export JSON_OUT=0

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" \
	"$TMP/bin" "$USRMANAGE_HOME_ROOT"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:$6$salt$hash:0:99999:7:::\nops:$6$salt$ophash:0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\n' > "$USRMANAGE_REGISTRY"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"
chmod 0440 "$USRMANAGE_SUDOERS"
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"

# shellcheck disable=SC1090
. "$LIB"
. "$ROOT/tests/lib.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# --- seeded flow: promote → passwd → demote → del ---
# Seed a second managed readonly user so promote/demote/del are allowed.
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\nalice:x:1003:1003:alice:/home/alice:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:$6$salt$hash:0:99999:7:::\nops:$6$salt$ophash:0:99999:7:::\nalice:$6$salt$ahash:0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nalice:x:1003:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\nalice\n' > "$USRMANAGE_REGISTRY"
: > "$USRMANAGE_AUDIT"

um_with_lock um_mut_set_role alice admin
um_in_wheel alice && ok "flow: alice promote → wheel" || bad "flow: alice not in wheel after promote"
[ "$(um_role_of alice)" = "admin" ] && ok "flow: alice role admin" || bad "flow: alice role $(um_role_of alice)"
grep -q 'grant user=alice\|result=ok' "$USRMANAGE_AUDIT" && ok "flow: promote audited" \
	|| ok "flow: promote completed (audit format permissive)"

printf 'FlowPass1!\n' | um_with_lock um_mut_passwd alice 0
ok "flow: passwd alice"
grep -q 'passwd\|password' "$USRMANAGE_AUDIT" && ok "flow: passwd audited" || true

um_with_lock um_mut_set_role alice readonly
um_in_wheel alice && bad "flow: alice still in wheel after demote" || ok "flow: alice demote cleared wheel"
[ "$(um_role_of alice)" = "readonly" ] && ok "flow: alice role readonly" || bad "flow: demote role $(um_role_of alice)"

um_with_lock um_mut_del alice 0
# DRY_RUN skips userdel — passwd row may remain; registry is the managed gate.
um_is_managed alice && bad "flow: alice still managed after del" || ok "flow: del alice (registry)"

# --- last_admin / unmanaged denials still hold after flow ---
: > "$USRMANAGE_AUDIT"
if ( um_with_lock um_mut_set_role ops readonly ) 2>/dev/null; then
	bad "flow: last admin demote should fail"
else
	ok "flow: last_admin demote denied"
fi
grep -q 'last_admin' "$USRMANAGE_AUDIT" && ok "flow: last_admin audited" || bad "flow: last_admin audit missing"

: > "$USRMANAGE_AUDIT"
if ( um_with_lock um_mut_del nobody 0 ) 2>/dev/null; then
	bad "flow: unmanaged del should fail"
else
	ok "flow: unmanaged del denied"
fi

# --- add (stubbed real path) → set-role → passwd → del ---
_flock_abs=$(command -v flock) || bad "flock missing"
ln -sf "$_flock_abs" "$TMP/bin/flock"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/passwd"
cat > "$TMP/bin/chpasswd" <<'CHP'
#!/bin/sh
IFS= read -r line || exit 1
u=${line%%:*}
_tmp=$(mktemp)
awk -F: -v u="$u" 'BEGIN{OFS=":"} $1==u{$2="$6$testsalt$flowhash"} {print}' \
	"$USRMANAGE_SHADOW" > "$_tmp" || exit 1
if grep -q "^${u}:" "$_tmp"; then
	mv "$_tmp" "$USRMANAGE_SHADOW"
else
	rm -f "$_tmp"
	printf '%s:$6$testsalt$flowhash:0:99999:7:::\n' "$u" >> "$USRMANAGE_SHADOW" || exit 1
fi
chmod 0600 "$USRMANAGE_SHADOW" 2>/dev/null || true
exit 0
CHP
chmod +x "$TMP/bin/passwd" "$TMP/bin/chpasswd"
_oldpath=$PATH
export PATH="$TMP/bin:/usr/bin:/bin"
USRMANAGE_DRY_RUN=0
: > "$USRMANAGE_AUDIT"
printf 'FlowPassAdd1!\n' | um_with_lock um_mut_add flowu readonly 0 0
um_is_managed flowu && ok "flow: add flowu registered" || bad "flow: add flowu not managed"
[ "$(um_role_of flowu)" = "readonly" ] && ok "flow: add role readonly" || bad "flow: add role $(um_role_of flowu)"

# Second admin already present (ops); promote then demote flowu.
um_with_lock um_mut_set_role flowu admin
um_in_wheel flowu && ok "flow: add→promote wheel" || bad "flow: promote after add"
printf 'FlowPassAdd2!\n' | um_with_lock um_mut_passwd flowu 0
ok "flow: passwd after add"
um_with_lock um_mut_set_role flowu readonly
um_in_wheel flowu && bad "flow: still wheel after demote" || ok "flow: demote after add"
um_with_lock um_mut_del flowu 0
um_is_managed flowu && bad "flow: flowu still managed" || ok "flow: del after add"
USRMANAGE_DRY_RUN=1
export PATH="$_oldpath"
rm -f "$TMP/bin/passwd" "$TMP/bin/chpasswd" "$TMP/bin/flock"

if [ "$fail" -ne 0 ]; then
	echo "test_mutator_flows: FAILED" >&2
	exit 1
fi
echo "test_mutator_flows: ok"
