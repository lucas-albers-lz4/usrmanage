#!/bin/sh
# Read-path error handling for protected registry/audit files (#180).
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CLI="$ROOT/openwrt-feed/usrmanage/files/usr/sbin/usrmanage"
TMP=$(mktemp -d)
trap 'chmod -R u+rwx "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

ETC="$TMP/etc"
LOG="$TMP/log"
LOCK="$TMP/lock/usrmanage.lock"
mkdir -p "$ETC" "$LOG" "$(dirname "$LOCK")"
chmod 0755 "$TMP" "$ETC" "$LOG" "$(dirname "$LOCK")"
printf 'root:x:0:0:root:/root:/bin/sh\nbob:x:1000:1000:bob:/home/bob:/bin/sh\n' > "$TMP/passwd"
printf 'root:!:0:99999:7:::\nbob:!:0:99999:7:::\n' > "$TMP/shadow"
printf 'root:x:0:\nwheel:x:10:\n' > "$TMP/group"
printf 'bob\n' > "$ETC/users"
printf 'event fixture\n' > "$LOG/audit.log"
touch "$TMP/sudoers" "$TMP/rpcd"
chmod 0644 "$TMP/passwd" "$TMP/shadow" "$TMP/group" "$TMP/sudoers" "$TMP/rpcd"
chmod 000 "$ETC/users" "$LOG/audit.log"

# Root can emulate a real unprivileged account; non-root host runs test as itself.
RUNUSER=$(command -v runuser || true)
if [ "$(id -u)" = 0 ]; then
	[ -n "$RUNUSER" ] || { echo "FAIL: runuser required to test protected files as non-root" >&2; exit 1; }
	TEST_UID=$(id -u nobody)
	[ "$TEST_UID" -ne 0 ] || { echo "FAIL: nobody must be unprivileged" >&2; exit 1; }
	RUN_AS_NOBODY=1
else
	RUN_AS_NOBODY=0
fi

run_cli() {
	if [ "$RUN_AS_NOBODY" = 1 ]; then
		"$RUNUSER" -u nobody -- env \
			PATH="${USRMANAGE_TEST_PATH:-$PATH}" \
			USRMANAGE_TEST_OVERRIDES=1 USRMANAGE_ETC="$ETC" \
			USRMANAGE_REGISTRY="$ETC/users" USRMANAGE_AUDIT_DIR="$LOG" \
			USRMANAGE_AUDIT="$LOG/audit.log" USRMANAGE_LOCK="$LOCK" \
			USRMANAGE_INCOMPLETE="$ETC/incomplete" USRMANAGE_PASSWD="$TMP/passwd" \
			USRMANAGE_SHADOW="$TMP/shadow" USRMANAGE_GROUP="$TMP/group" \
			USRMANAGE_SUDOERS="$TMP/sudoers" USRMANAGE_RPCD_CONFIG="$TMP/rpcd" \
			USRMANAGE_HOME_ROOT="$TMP/home" "$CLI" "$@"
	else
		PATH="${USRMANAGE_TEST_PATH:-$PATH}" USRMANAGE_TEST_OVERRIDES=1 USRMANAGE_ETC="$ETC" \
			USRMANAGE_REGISTRY="$ETC/users" USRMANAGE_AUDIT_DIR="$LOG" \
			USRMANAGE_AUDIT="$LOG/audit.log" USRMANAGE_LOCK="$LOCK" \
			USRMANAGE_INCOMPLETE="$ETC/incomplete" USRMANAGE_PASSWD="$TMP/passwd" \
			USRMANAGE_SHADOW="$TMP/shadow" USRMANAGE_GROUP="$TMP/group" \
			USRMANAGE_SUDOERS="$TMP/sudoers" USRMANAGE_RPCD_CONFIG="$TMP/rpcd" \
			USRMANAGE_HOME_ROOT="$TMP/home" "$CLI" "$@"
	fi
}

fail=0
if _list=$(run_cli list --json 2>"$TMP/list.err"); then
	echo "FAIL: list should fail on unreadable registry" >&2
	fail=1
else
	case "$_list" in
		*'"users":['*) echo "FAIL: list emitted partial JSON: $_list" >&2; fail=1 ;;
		*'"error":"read_failed"'*) echo "ok: list fails closed on unreadable registry" ;;
		*) echo "FAIL: list error reply: $_list" >&2; fail=1 ;;
	esac
fi

if _audit=$(run_cli audit --json 2>"$TMP/audit.err"); then
	echo "FAIL: audit should fail on unreadable log" >&2
	fail=1
else
	case "$_audit" in
		*'"events":['*) echo "FAIL: audit emitted partial/empty JSON: $_audit" >&2; fail=1 ;;
		*'"error":"read_failed"'*) echo "ok: audit fails closed on unreadable log" ;;
		*) echo "FAIL: audit error reply: $_audit" >&2; fail=1 ;;
	esac
fi

# A tail process that emits partial data and then fails must not produce JSON.
chmod 0644 "$LOG/audit.log"
mkdir -p "$TMP/failtail"
cat >"$TMP/failtail/tail" <<'TAIL'
#!/bin/sh
printf 'partial event line\n'
exit 1
TAIL
chmod +x "$TMP/failtail/tail"
if _audit=$(USRMANAGE_TEST_PATH="$TMP/failtail:$PATH" run_cli audit --json 2>"$TMP/tail.err"); then
	echo "FAIL: audit accepted tail failure" >&2
	fail=1
else
	case "$_audit" in
		*'"events":['*) echo "FAIL: audit emitted partial JSON after tail failure: $_audit" >&2; fail=1 ;;
		*'"error":"read_failed"'*) echo "ok: audit fails closed on tail error" ;;
		*) echo "FAIL: tail error reply: $_audit" >&2; fail=1 ;;
	esac
fi

[ "$fail" -eq 0 ] || exit 1
echo "read-path tests passed"
