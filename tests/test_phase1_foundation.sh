#!/bin/sh
# Host tests for Phase 1: um_atomic_edit, um_alloc_ids, um_tx_* snapshots.
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
export USRMANAGE_RPCD_CONFIG="$TMP/rpcd"
export USRMANAGE_UID_FLOOR=1000
export USRMANAGE_SRC=cli
export USRMANAGE_ACTOR=testhost
# Hermetic tests rely on USRMANAGE_* path overrides; enable the test-only gate.
export USRMANAGE_TEST_OVERRIDES=1

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1000:1000:ops:/home/ops:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\nops:!::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nops:x:1000:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\n' > "$USRMANAGE_REGISTRY"
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"

# shellcheck disable=SC1090
. "$LIB"
. "$ROOT/tests/lib.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# --- um_atomic_edit ---
printf 'a:1\nb:2\n' > "$TMP/atomic.txt"
chmod 0644 "$TMP/atomic.txt"
um_atomic_edit "$TMP/atomic.txt" 0644 -F: 'BEGIN{OFS=":"} $1=="b"{$2="9"} {print}'
grep -qx 'b:9' "$TMP/atomic.txt" && ok "um_atomic_edit rewrites" || bad "um_atomic_edit rewrite"
_mode=$(stat_mode "$TMP/atomic.txt")
case "$_mode" in
	*644*|*-rw-r--r--*) ok "um_atomic_edit mode 0644" ;;
	*) bad "um_atomic_edit mode got $_mode" ;;
esac

# temp never world-readable: inject failing awk; ensure no leftover world-readable tmp
printf 'x\n' > "$TMP/atomic2.txt"
chmod 0644 "$TMP/atomic2.txt"
if um_atomic_edit "$TMP/atomic2.txt" 0644 'BEGIN{exit 1}'; then
	bad "um_atomic_edit should fail on awk exit 1"
else
	ok "um_atomic_edit fails on awk error"
fi
_leftover=$(find "$TMP" -name 'atomic2.txt.tmp.*' 2>/dev/null | wc -l | tr -d ' ')
[ "$_leftover" = "0" ] && ok "um_atomic_edit cleans temp on failure" || bad "leftover tmp files"

# original preserved on failure
printf 'keep-me\n' > "$TMP/atomic3.txt"
um_atomic_edit "$TMP/atomic3.txt" 0644 'BEGIN{exit 1}' || true
grep -qx 'keep-me' "$TMP/atomic3.txt" && ok "original preserved on failure" || bad "original lost"

# --- um_alloc_ids ---
_ids=$(um_alloc_ids) || { bad "um_alloc_ids basic"; _ids=; }
[ "$_ids" = "1001 1001" ] && ok "um_alloc_ids skips occupied 1000" || bad "um_alloc_ids got '$_ids' want 1001 1001"

# gid collision: uid 1002 free in passwd but gid 1002 taken in group
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1000:1000:ops:/home/ops:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:x:0:\nops:x:1000:\nother:x:1002:\nwheel:x:10:\n' > "$USRMANAGE_GROUP"
_ids=$(um_alloc_ids) || { bad "um_alloc_ids gid collision"; _ids=; }
[ "$_ids" = "1001 1001" ] && ok "um_alloc_ids advances past gid collision" || bad "gid collision got '$_ids'"

# range exhaustion
export USRMANAGE_UID_FLOOR=60000
printf 'root:x:0:0:root:/root:/bin/ash\nz:x:60000:60000:z:/home/z:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:x:0:\nz:x:60000:\n' > "$USRMANAGE_GROUP"
: > "$USRMANAGE_AUDIT"
if um_alloc_ids >/dev/null 2>&1; then
	bad "um_alloc_ids should exhaust"
else
	ok "um_alloc_ids range exhaustion"
fi
grep -q 'reason=uid_range_exhausted' "$USRMANAGE_AUDIT" && ok "exhaustion audited" || bad "exhaustion not audited"
export USRMANAGE_UID_FLOOR=1000

# --- um_tx snapshot / rollback ---
printf 'root:x:0:0:root:/root:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\n' > "$USRMANAGE_GROUP"
printf 'ops\n' > "$USRMANAGE_REGISTRY"
um_tx_begin
printf 'root:x:0:0:root:/root:/bin/ash\nbad:x:1000:1000::/:/bin/ash\n' > "$USRMANAGE_PASSWD"
um_tx_rollback
grep -q 'bad:' "$USRMANAGE_PASSWD" && bad "tx rollback left bad user" || ok "tx rollback restores passwd"
grep -qx 'ops' "$USRMANAGE_REGISTRY" && ok "tx rollback restores registry" || bad "registry not restored"

# rpcd config is part of the snapshot (issue #94 M3): rollback restores it too.
um_tx_begin
printf 'config login\n\toption username '\''x'\''\n' >> "$USRMANAGE_RPCD_CONFIG"
um_tx_rollback
grep -q "option username 'x'" "$USRMANAGE_RPCD_CONFIG" && bad "tx rollback left rpcd login" || ok "tx rollback restores rpcd config"
grep -q 'config rpcd' "$USRMANAGE_RPCD_CONFIG" && ok "rpcd fixture intact" || bad "rpcd fixture lost"

um_tx_begin
printf 'changed\n' > "$USRMANAGE_REGISTRY"
um_tx_commit
grep -qx 'changed' "$USRMANAGE_REGISTRY" && ok "tx commit keeps changes" || bad "tx commit lost changes"
# rollback after commit must be no-op
um_tx_rollback
grep -qx 'changed' "$USRMANAGE_REGISTRY" && ok "tx rollback after commit is no-op" || bad "commit undone"

# nested begin must fail
um_tx_begin
if ( um_tx_begin ) >/dev/null 2>&1; then
	bad "nested um_tx_begin should fail"
else
	ok "nested um_tx_begin rejected"
fi
um_tx_commit

# partial restore must fail the rollback (not return success) and keep snapdir
um_tx_begin
_snap_keep=$UM_TX_SNAPDIR
rm -f "$UM_TX_SNAPDIR/passwd" "$UM_TX_SNAPDIR/passwd.missing"
_rb_err=$TMP/rb_err.txt
if um_tx_rollback 2>"$_rb_err"; then
	bad "tx rollback should fail when snapshot incomplete"
else
	ok "tx rollback fails on incomplete snapshot"
fi
[ -d "$_snap_keep" ] && ok "snapdir kept after failed restore" || bad "snapdir removed on failed restore"
grep -q "tx_restore_failed path=$_snap_keep" "$_rb_err" \
	&& ok "failed restore reports snapdir path" \
	|| bad "error missing snapdir path: $(cat "$_rb_err")"
# Cleanup leftover recovery snapdir from this test
rm -rf "$_snap_keep"

# I4: restore applies fixed modes via temp+rename (not bare cp onto live files).
chmod 0644 "$USRMANAGE_PASSWD"
chmod 0600 "$USRMANAGE_SHADOW"
chmod 0644 "$USRMANAGE_GROUP"
chmod 0640 "$USRMANAGE_REGISTRY"
chmod 0600 "$USRMANAGE_RPCD_CONFIG"
um_tx_begin
printf 'root:x:0:0:root:/root:/bin/ash\nbad:x:1000:1000::/:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\nbad:!::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'torn-rpcd\n' > "$USRMANAGE_RPCD_CONFIG"
# Deliberately wrong modes mid-tx — restore must re-apply policy modes.
chmod 0666 "$USRMANAGE_PASSWD" "$USRMANAGE_SHADOW" "$USRMANAGE_RPCD_CONFIG"
um_tx_rollback
grep -q 'bad:' "$USRMANAGE_PASSWD" && bad "I4 rollback left bad passwd" || ok "I4 rollback restores passwd content"
_mode=$(stat_mode "$USRMANAGE_PASSWD")
[ "$_mode" = "644" ] && ok "I4 passwd mode 0644 after restore" || bad "I4 passwd mode $_mode"
_mode=$(stat_mode "$USRMANAGE_SHADOW")
[ "$_mode" = "600" ] && ok "I4 shadow mode 0600 after restore" || bad "I4 shadow mode $_mode"
_mode=$(stat_mode "$USRMANAGE_RPCD_CONFIG")
[ "$_mode" = "600" ] && ok "I4 rpcd mode 0600 after restore" || bad "I4 rpcd mode $_mode"

# I4: failed mv leaves live destination unchanged (no in-place truncate).
um_tx_begin
_snap_keep=$UM_TX_SNAPDIR
printf 'live-torn\n' > "$USRMANAGE_PASSWD"
mkdir -p "$TMP/failbin"
printf '#!/bin/sh\nexit 1\n' > "$TMP/failbin/mv"
chmod +x "$TMP/failbin/mv"
if ( PATH="$TMP/failbin:$PATH" um_tx_rollback ) >/dev/null 2>&1; then
	bad "I4 rollback should fail when mv fails"
else
	ok "I4 rollback fails when mv fails"
fi
grep -qx 'live-torn' "$USRMANAGE_PASSWD" \
	&& ok "I4 failed restore preserves live destination" \
	|| bad "I4 failed restore mutated destination"
[ -d "$_snap_keep" ] && ok "I4 snapdir kept after mv failure" || bad "I4 snapdir lost after mv failure"
rm -rf "$_snap_keep" "$TMP/failbin"
UM_TX_ACTIVE=0
UM_TX_SNAPDIR=
UM_TX_COMMITTED=0
# Reset passwd after failed restore left torn content.
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1000:1000:ops:/home/ops:/bin/ash\n' > "$USRMANAGE_PASSWD"
chmod 0644 "$USRMANAGE_PASSWD"

# mid-begin snap failure must not leave orphaned snapdirs (EXIT hook + aborted-begin cleanup)
_tx_tmp=$TMP/tx_begin_fail
mkdir -p "$_tx_tmp"
_snaps_before=0
for _d in "$_tx_tmp"/usrmanage-tx.*; do
	[ -d "$_d" ] || continue
	_snaps_before=$((_snaps_before + 1))
done
if (
	TMPDIR=$_tx_tmp
	export TMPDIR
	um_tx_snap_one() { return 1; }
	um_tx_begin
) >/dev/null 2>&1; then
	bad "um_tx_begin should fail when snap fails"
else
	ok "um_tx_begin fails when snap fails"
fi
_snaps_after=0
for _d in "$_tx_tmp"/usrmanage-tx.*; do
	[ -d "$_d" ] || continue
	_snaps_after=$((_snaps_after + 1))
done
[ "$_snaps_after" -eq "$_snaps_before" ] \
	&& ok "no orphan snapdir on begin failure" \
	|| bad "orphaned snapdir after begin failure (before=$_snaps_before after=$_snaps_after)"

# --- registry D3 modes ---
printf 'ops\n' > "$USRMANAGE_REGISTRY"
chmod 0640 "$USRMANAGE_REGISTRY"
um_registry_add alice
_mode=$(stat_mode "$USRMANAGE_REGISTRY")
[ "$_mode" = "640" ] && ok "registry mode 0640 after add" || bad "registry mode after add: $_mode"
_own=$(stat_owner "$USRMANAGE_REGISTRY")
if [ "$(id -u)" = "0" ]; then
	[ "$_own" = "0 0" ] && ok "registry owner 0:0 after add" || bad "registry owner after add: $_own"
else
	ok "registry ownership skip (non-root; chown 0:0 no-op)"
fi
um_registry_del alice
_mode=$(stat_mode "$USRMANAGE_REGISTRY")
[ "$_mode" = "640" ] && ok "registry mode 0640 after del" || bad "registry mode after del: $_mode"
_own=$(stat_owner "$USRMANAGE_REGISTRY")
if [ "$(id -u)" = "0" ]; then
	[ "$_own" = "0 0" ] && ok "registry owner 0:0 after del" || bad "registry owner after del: $_own"
else
	ok "registry ownership skip after del (non-root)"
fi
grep -qx 'alice' "$USRMANAGE_REGISTRY" && bad "alice still in registry" || ok "registry_del removed alice"
if [ "$fail" -ne 0 ]; then
	echo "phase1 foundation tests FAILED" >&2
	exit 1
fi
echo "phase1 foundation tests OK"
