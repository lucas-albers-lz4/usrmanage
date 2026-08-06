#!/bin/sh
# Host tests for mutators under lock + rpcd argv (Zen MCR M9).
# Uses USRMANAGE_DRY_RUN=1 — no real useradd/chpasswd.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"
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
export USRMANAGE_DRY_RUN=1
export USRMANAGE_SRC=cli
export USRMANAGE_ACTOR=testhost

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$TMP/bin"
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

# --- lock ---
_mark_touch() {
	printf '1\n' > "$TMP/lock_ran"
}
rm -f "$TMP/lock_ran"
um_with_lock _mark_touch
[ -f "$TMP/lock_ran" ] && ok "um_with_lock runs body" || bad "um_with_lock body"
[ -f "$USRMANAGE_LOCK" ] && ok "lock file created" || bad "lock file missing"

# flock required when flock not on PATH
mkdir -p "$TMP/emptybin"
if ( PATH="$TMP/emptybin" um_with_lock _mark_touch ) 2>/dev/null; then
	bad "um_with_lock without flock should fail"
else
	ok "um_with_lock fails without flock"
fi

# exclusive: hold lock in background; non-blocking flock -n must fail
(
	flock -x 9
	sleep 3
) 9>"$USRMANAGE_LOCK" &
_hold=$!
sleep 0.2
if flock -n 9 9>"$USRMANAGE_LOCK"; then
	bad "flock -n acquired while held"
	# release accidental acquire
	flock -u 9 9>"$USRMANAGE_LOCK" 2>/dev/null || true
else
	ok "flock exclusive blocks concurrent acquire"
fi
wait "$_hold" 2>/dev/null || true

# --- mutator denials under lock ---
: > "$USRMANAGE_AUDIT"
if ( um_with_lock um_mut_set_role ops readonly ) 2>/dev/null; then
	bad "demote last admin should fail"
else
	ok "last_admin demote denied under lock"
fi
grep -q 'denied.*last_admin\|reason=last_admin' "$USRMANAGE_AUDIT" && ok "last_admin audited" || bad "last_admin audit: $(tail -3 "$USRMANAGE_AUDIT")"

: > "$USRMANAGE_AUDIT"
if ( um_with_lock um_mut_del nobody 0 ) 2>/dev/null; then
	bad "del unmanaged should fail"
else
	ok "unmanaged del denied under lock"
fi
grep -q 'denied' "$USRMANAGE_AUDIT" && ok "unmanaged del audited" || bad "unmanaged del audit"

# --- mutator success under DRY_RUN ---
um_with_lock um_mut_set_role audit admin
um_in_wheel audit && ok "set-role audit→admin under lock" || bad "audit not in wheel after promote"
grep -q 'grant user=audit\|result=ok' "$USRMANAGE_AUDIT" && ok "promote audited" || true

printf 'goodpass1\n' | um_with_lock um_mut_passwd audit 0
ok "passwd under lock (DRY_RUN)"

um_with_lock um_mut_del audit 0
um_is_managed audit && bad "audit still managed after del" || ok "del audit under lock"
um_in_wheel audit && bad "audit still in wheel after del" || ok "del cleared wheel"

# restore audit for clarity of leftover state (optional)
printf 'ops\n' > "$USRMANAGE_REGISTRY"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"

# --- rpcd argv: stub CLI ---
cat > "$TMP/bin/usrmanage-stub" <<'STUB'
#!/bin/sh
# Log argc/argv; never print passwords from stdin beyond marking presence.
log="${USRMANAGE_STUB_LOG:?}"
{
	printf 'argc=%s\n' "$#"
	i=1
	for a in "$@"; do
		printf 'arg%d=%s\n' "$i" "$a"
		i=$((i + 1))
	done
	if [ -t 0 ]; then
		printf 'stdin=empty\n'
	else
		# Read one line without echoing content into the log (password-safe).
		IFS= read -r _line || _line=
		if [ -n "$_line" ]; then
			printf 'stdin=nonempty len=%s\n' "${#_line}"
		else
			printf 'stdin=empty\n'
		fi
	fi
} > "$log"
printf '{"ok":true,"stub":true}\n'
STUB
chmod +x "$TMP/bin/usrmanage-stub"

# Minimal jsonfilter mock for @.field string/number/bool
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
# Prefer quoted string value
val=$(printf '%s' "$inp" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n1)
if [ -z "$val" ]; then
	val=$(printf '%s' "$inp" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\([^,}[:space:]]*\\).*/\\1/p" | head -n1)
fi
printf '%s' "$val"
JF
chmod +x "$TMP/bin/jsonfilter"

export USRMANAGE_BIN="$TMP/bin/usrmanage-stub"
export USRMANAGE_STUB_LOG="$TMP/stub.log"
export PATH="$TMP/bin:$PATH"

rm -f "$USRMANAGE_STUB_LOG"
sh "$RPCD" call show '{"name":"x --actor root"}' >/dev/null
grep -q 'arg1=show' "$USRMANAGE_STUB_LOG" && ok "rpcd show arg1=show" || bad "rpcd show argv: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg2=x --actor root' "$USRMANAGE_STUB_LOG" && ok "rpcd show keeps name as one argv" || bad "rpcd show name split"
grep -q 'arg3=--json' "$USRMANAGE_STUB_LOG" && ok "rpcd show --json" || bad "rpcd show missing --json"
# Must not inject a separate --actor CLI flag from the name
grep -E 'arg[0-9]+=--actor$' "$USRMANAGE_STUB_LOG" && bad "rpcd injected --actor flag" || ok "rpcd no --actor injection"

rm -f "$USRMANAGE_STUB_LOG"
sh "$RPCD" call set_role '{"name":"ops","role":"readonly"}' >/dev/null
grep -q 'arg1=set-role' "$USRMANAGE_STUB_LOG" && ok "rpcd set_role → set-role" || bad "rpcd set_role cmd"
grep -q 'arg2=ops' "$USRMANAGE_STUB_LOG" && ok "rpcd set_role name" || bad "rpcd set_role name"
grep -q 'arg3=readonly' "$USRMANAGE_STUB_LOG" && ok "rpcd set_role role" || bad "rpcd set_role role"

rm -f "$USRMANAGE_STUB_LOG"
sh "$RPCD" call add '{"name":"newuser","role":"readonly","password":"LabPass1!"}' >/dev/null
grep -q 'arg1=add' "$USRMANAGE_STUB_LOG" && ok "rpcd add cmd" || bad "rpcd add cmd"
grep -q 'arg3=--role' "$USRMANAGE_STUB_LOG" && ok "rpcd add --role" || bad "rpcd add --role: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg5=--password-fd' "$USRMANAGE_STUB_LOG" && ok "rpcd add --password-fd" || bad "rpcd add password-fd flag: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg6=0' "$USRMANAGE_STUB_LOG" && ok "rpcd add password-fd 0" || bad "rpcd add fd number"
grep -q 'stdin=nonempty' "$USRMANAGE_STUB_LOG" && ok "rpcd add password on stdin" || bad "rpcd add stdin"
# Password must not appear in stub argv log
grep -F 'LabPass1!' "$USRMANAGE_STUB_LOG" && bad "password leaked into stub log" || ok "password not in stub argv log"

# jsonfilter required when missing from PATH (keep /bin for sh builtins' external helpers)
mv "$TMP/bin/jsonfilter" "$TMP/bin/jsonfilter.bak"
out=$(sh "$RPCD" call list '{}' 2>/dev/null) || true
mv "$TMP/bin/jsonfilter.bak" "$TMP/bin/jsonfilter"
echo "$out" | grep -q 'jsonfilter_required' && ok "rpcd jsonfilter_required" || bad "rpcd missing jsonfilter: $out"

[ "$fail" = "0" ] || exit 1
echo "ALL MUTATOR/LOCK/RPCD TESTS PASSED"
