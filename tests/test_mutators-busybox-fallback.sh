#!/bin/sh
# Host tests for busybox/manual account mutation fallbacks (Phase 4 / #28).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export USRMANAGE_ETC="$TMP/etc" USRMANAGE_REGISTRY="$TMP/etc/users" USRMANAGE_AUDIT_DIR="$TMP/log"
export USRMANAGE_AUDIT="$TMP/log/audit.log" USRMANAGE_LOCK="$TMP/lock/usrmanage.lock"
export USRMANAGE_INCOMPLETE="$TMP/etc/incomplete" USRMANAGE_PASSWD="$TMP/passwd"
export USRMANAGE_SHADOW="$TMP/shadow" USRMANAGE_GROUP="$TMP/group" USRMANAGE_SUDOERS="$TMP/sudoers"
export USRMANAGE_RPCD_CONFIG="$TMP/rpcd"
export USRMANAGE_HOME_ROOT="$TMP/home" USRMANAGE_UID_FLOOR=1000 USRMANAGE_SHELL=/bin/sh
export USRMANAGE_SRC=cli USRMANAGE_ACTOR=testhost USRMANAGE_DRY_RUN=0
# Hermetic tests rely on USRMANAGE_* path overrides; enable the test-only gate.
export USRMANAGE_TEST_OVERRIDES=1
mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$USRMANAGE_HOME_ROOT"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT" "$USRMANAGE_SUDOERS"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:\n' > "$USRMANAGE_GROUP"
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
chmod 0644 "$USRMANAGE_PASSWD" "$USRMANAGE_GROUP"
chmod 0600 "$USRMANAGE_SHADOW"

# Shim dir for the stock-BusyBox PATH simulation. flock is a hard product
# requirement (um_with_lock) — resolve it to an absolute path BEFORE narrowing
# PATH so the test does not depend on where the binary lives (Homebrew puts
# it under /opt/homebrew or /usr/local, not /usr/bin).
HOSTBIN="$TMP/hostbin"
mkdir -p "$HOSTBIN"
_flock_abs=$(command -v flock) || { echo "FAIL: flock missing (Linux: util-linux, macOS: brew install flock)" >&2; exit 1; }
ln -s "$_flock_abs" "$HOSTBIN/flock"

# Shadow host account tools the simulated image must never reach. On macOS,
# /usr/bin/passwd -l means "location", not "lock"; pkill would scan the real
# host. Stub them so the mutators deterministically take the manual file
# fallback instead of running the host's own binaries.
for _t in passwd pkill; do
	printf '#!/bin/sh\nexit 1\n' > "$HOSTBIN/$_t"
	chmod +x "$HOSTBIN/$_t"
done

export PATH="$HOSTBIN:/usr/bin:/bin"
command -v useradd >/dev/null 2>&1 && { echo "FAIL: useradd on PATH" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "FAIL: flock not reachable on pinned PATH" >&2; exit 1; }
# shellcheck disable=SC1090
. "$LIB"
. "$ROOT/tests/lib.sh"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
um_create_user bob readonly || bad "create bob"
grep -q '^bob:' "$USRMANAGE_PASSWD" && ok "passwd entry" || bad "passwd missing"
grep -q '^bob:' "$USRMANAGE_GROUP" && ok "group entry" || bad "group missing"
grep -q '^bob:!' "$USRMANAGE_SHADOW" && ok "shadow locked placeholder" || bad "shadow placeholder"
_aging=$(awk -F: -v u=bob '$1==u{print $4,$5}' "$USRMANAGE_SHADOW")
[ "$_aging" = "0 99999" ] && ok "placeholder aging min/max" || bad "placeholder aging '$_aging'"
[ -d "$USRMANAGE_HOME_ROOT/bob" ] && ok "home created" || bad "home missing"
_mode=$(stat_mode "$USRMANAGE_HOME_ROOT/bob"); [ "$_mode" = "750" ] && ok "home mode 0750" || bad "home mode $_mode"
_mode=$(stat_mode "$USRMANAGE_SHADOW"); [ "$_mode" = "600" ] && ok "shadow mode 0600" || bad "shadow mode $_mode"
_mode=$(stat_mode "$USRMANAGE_PASSWD"); [ "$_mode" = "644" ] && ok "passwd mode 0644" || bad "passwd mode $_mode"
um_registry_add bob || bad "registry_add bob"
_mode=$(stat_mode "$USRMANAGE_REGISTRY"); [ "$_mode" = "640" ] && ok "registry mode 0640" || bad "registry mode $_mode"
_own=$(stat_owner "$USRMANAGE_REGISTRY")
if [ "$(id -u)" = "0" ]; then
	[ "$_own" = "0 0" ] && ok "registry owner 0:0 after add" || bad "registry owner after add: $_own"
else
	ok "registry ownership skip (non-root; chown 0:0 no-op)"
fi
grep -q 'passwd -a sha512' "$LIB" && ok "passwd -a sha512 pinned" || bad "sha512 pin missing"
# shellcheck disable=SC2016
um_atomic_edit "$USRMANAGE_SHADOW" 0600 -v u=bob -F: 'BEGIN{OFS=":"} $1==u{$2="$6$testsalt$testhash"} {print}'
grep -q '^bob:\$6\$' "$USRMANAGE_SHADOW" && ok "hash prefix \$6\$" || bad "hash not \$6\$"
_aging=$(awk -F: -v u=bob '$1==u{print $4,$5}' "$USRMANAGE_SHADOW")
[ "$_aging" = "0 99999" ] && ok "aging min/max after hash" || bad "aging after hash '$_aging'"
um_lock_account bob || bad "lock bob"
um_user_locked bob && ok "bob locked" || bad "bob not locked"
um_lock_account bob || bad "lock idempotent"
um_user_locked bob && ok "still locked" || bad "unlocked after second lock"
um_delete_account bob 0 || bad "delete no-purge"
grep -q '^bob:' "$USRMANAGE_PASSWD" && bad "passwd still has bob" || ok "passwd entry removed"
[ -d "$USRMANAGE_HOME_ROOT/bob" ] && ok "home kept without purge" || bad "home removed without purge"
um_create_user carol readonly || bad "create carol"
um_delete_account carol 1 || bad "delete purge"
[ -d "$USRMANAGE_HOME_ROOT/carol" ] && bad "home not purged" || ok "home purged"
um_create_user dave readonly || bad "create dave"
# shellcheck disable=SC2016
um_atomic_edit "$USRMANAGE_GROUP" 0644 -v u=dave -F: 'BEGIN{OFS=":"} $1==u{$4="dave,other"} {print}'
: > "$USRMANAGE_AUDIT"
if um_group_entry_del dave 2>/dev/null; then bad "group_has_members should fail"; else ok "group_has_members denied"; fi
grep -q 'group_has_members' "$USRMANAGE_AUDIT" && ok "group_has_members audited" || bad "not audited"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:\n' > "$USRMANAGE_GROUP"
: > "$USRMANAGE_REGISTRY"
um_tx_begin
um_passwd_entry_add eve 1010 1010 "$USRMANAGE_HOME_ROOT/eve" /bin/sh
um_tx_rollback
grep -q '^eve:' "$USRMANAGE_PASSWD" && bad "eve remained after rollback" || ok "snapshot restore on failure"
printf 'root:x:0:0:root:/root:/bin/sh\nmix:x:1020:1020:mix:%s/mix:/bin/sh\n' "$USRMANAGE_HOME_ROOT" > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\nmix:\$2b\$10\$abcdefghijklmnopqrstuu:0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nmix:x:1020:\nwheel:x:10:\n' > "$USRMANAGE_GROUP"
mkdir -p "$USRMANAGE_HOME_ROOT/mix"
um_lock_account mix || bad "lock mixed"
um_user_locked mix && ok "mixed lock" || bad "mixed not locked"
um_delete_account mix 1 || bad "delete mixed"
grep -q '^mix:' "$USRMANAGE_PASSWD" && bad "mix still in passwd" || ok "mixed delete"
[ "$fail" -eq 0 ] || { echo "busybox-fallback tests FAILED" >&2; exit 1; }
echo "busybox-fallback tests OK"
