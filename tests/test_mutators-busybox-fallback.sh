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
export USRMANAGE_HOME_ROOT="$TMP/home" USRMANAGE_UID_FLOOR=1000 USRMANAGE_SHELL=/bin/sh
export USRMANAGE_SRC=cli USRMANAGE_ACTOR=testhost USRMANAGE_DRY_RUN=0
mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$USRMANAGE_HOME_ROOT"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT" "$USRMANAGE_SUDOERS"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:\n' > "$USRMANAGE_GROUP"
chmod 0644 "$USRMANAGE_PASSWD" "$USRMANAGE_GROUP"
chmod 0600 "$USRMANAGE_SHADOW"
export PATH="/usr/bin:/bin"
command -v useradd >/dev/null 2>&1 && { echo "FAIL: useradd on PATH" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "FAIL: flock missing" >&2; exit 1; }
# shellcheck disable=SC1090
. "$LIB"
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
um_create_user bob readonly || bad "create bob"
grep -q '^bob:' "$USRMANAGE_PASSWD" && ok "passwd entry" || bad "passwd missing"
grep -q '^bob:' "$USRMANAGE_GROUP" && ok "group entry" || bad "group missing"
grep -q '^bob:!' "$USRMANAGE_SHADOW" && ok "shadow locked placeholder" || bad "shadow placeholder"
[ -d "$USRMANAGE_HOME_ROOT/bob" ] && ok "home created" || bad "home missing"
_mode=$(stat -c '%a' "$USRMANAGE_HOME_ROOT/bob"); [ "$_mode" = "750" ] && ok "home mode 0750" || bad "home mode $_mode"
_mode=$(stat -c '%a' "$USRMANAGE_SHADOW"); [ "$_mode" = "600" ] && ok "shadow mode 0600" || bad "shadow mode $_mode"
_mode=$(stat -c '%a' "$USRMANAGE_PASSWD"); [ "$_mode" = "644" ] && ok "passwd mode 0644" || bad "passwd mode $_mode"
grep -q 'passwd -a sha512' "$LIB" && ok "passwd -a sha512 pinned" || bad "sha512 pin missing"
# shellcheck disable=SC2016
um_atomic_edit "$USRMANAGE_SHADOW" 0600 -v u=bob -F: 'BEGIN{OFS=":"} $1==u{$2="$6$testsalt$testhash"} {print}'
grep -q '^bob:\$6\$' "$USRMANAGE_SHADOW" && ok "hash prefix \$6\$" || bad "hash not \$6\$"
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
