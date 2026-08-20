#!/bin/sh
# Host tests for mutators under lock + rpcd argv (issue #3 M9).
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
export USRMANAGE_RPCD_CONFIG="$TMP/rpcd"
export USRMANAGE_DRY_RUN=1
export USRMANAGE_SRC=cli
export USRMANAGE_ACTOR=testhost
# Hermetic tests rely on USRMANAGE_* path overrides; enable the test-only gate.
export USRMANAGE_TEST_OVERRIDES=1

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$TMP/bin"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\naudit:x:1001:1001:audit:/home/audit:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\nops:::0:99999:7:::\naudit:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\naudit\n' > "$USRMANAGE_REGISTRY"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"

# shellcheck disable=SC1090
. "$LIB"
. "$ROOT/tests/lib.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# --- lock ---
_mark_touch() {
	printf '1\n' > "$TMP/lock_ran"
}
rm -f "$TMP/lock_ran" "$USRMANAGE_LOCK"
umask 022
um_with_lock _mark_touch
[ -f "$TMP/lock_ran" ] && ok "um_with_lock runs body" || bad "um_with_lock body"
[ -f "$USRMANAGE_LOCK" ] && ok "lock file created" || bad "lock file missing"
_mode=$(stat_mode "$USRMANAGE_LOCK")
[ "$_mode" = "600" ] && ok "lock file mode 0600" || bad "lock file mode $_mode (want 600)"
# BusyBox flock lacks -w; pin the indefinite-block assumption in source.
grep -q 'blocks concurrent callers indefinitely' "$LIB" \
	&& ok "um_with_lock documents indefinite flock wait" \
	|| bad "um_with_lock missing indefinite-wait note"
grep -q 'flock -w' "$LIB" && bad "um_with_lock must not use flock -w (BusyBox)" \
	|| ok "um_with_lock avoids flock -w"

# Upgrade path: a lock left 0644 by an older build must be tightened (L7).
install -m 0644 /dev/null "$USRMANAGE_LOCK"
um_with_lock _mark_touch
_mode=$(stat_mode "$USRMANAGE_LOCK")
[ "$_mode" = "600" ] && ok "pre-existing 0644 lock tightened to 0600" \
	|| bad "pre-existing lock mode $_mode (want 600)"

# L11: doctor-first lock create must also be 0600 (not bare 9> under umask 022).
rm -f "$USRMANAGE_LOCK"
umask 022
um_doctor_checks >/dev/null 2>&1 || true
[ -f "$USRMANAGE_LOCK" ] && ok "doctor creates lock file" || bad "doctor did not create lock"
_mode=$(stat_mode "$USRMANAGE_LOCK")
[ "$_mode" = "600" ] && ok "doctor-first lock mode 0600 (L11)" \
	|| bad "doctor-first lock mode $_mode (want 600)"

# L12: incomplete marker must not inherit ambient umask 022 (0644).
rm -f "$USRMANAGE_INCOMPLETE"
umask 022
um_incomplete_set "passwd:alice"
[ -f "$USRMANAGE_INCOMPLETE" ] && ok "incomplete marker created" \
	|| bad "incomplete marker missing"
_mode=$(stat_mode "$USRMANAGE_INCOMPLETE")
[ "$_mode" = "640" ] && ok "incomplete marker mode 0640 (L12)" \
	|| bad "incomplete marker mode $_mode (want 640)"
um_incomplete_clear

# L10: passwd/shadow lookups are field-anchored (tp must not resolve to ntp).
cat > "$USRMANAGE_PASSWD" <<EOF
root:x:0:0:root:/root:/bin/ash
daemon:x:1:1:daemon:/var:/bin/false
ntp:x:123:123:NTP:$TMP/ntp_home:/bin/false
tp:x:1000:1000:tp:$TMP/tp_home:/bin/ash
EOF
mkdir -p "$TMP/ntp_home" "$TMP/tp_home"
[ "$(um_user_uid n 2>/dev/null || true)" = "" ] && ok "L10: show n does not match daemon" \
	|| bad "L10: n matched uid=$(um_user_uid n)"
[ "$(um_user_uid tp)" = "1000" ] && ok "L10: tp uid is 1000 not ntp" \
	|| bad "L10: tp uid=$(um_user_uid tp)"
[ "$(um_user_home tp)" = "$TMP/tp_home" ] && ok "L10: tp home not ntp home" \
	|| bad "L10: tp home=$(um_user_home tp)"
# restore account files used by later mutator tests
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\naudit:x:1001:1001:audit:/home/audit:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\nops:::0:99999:7:::\naudit:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"

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

# I5: post-commit registry_del failure must keep incomplete for doctor.
printf 'ops\naudit\n' > "$USRMANAGE_REGISTRY"
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\naudit:x:1001:1001:audit:/home/audit:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\nops:::0:99999:7:::\naudit:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops,audit\n' > "$USRMANAGE_GROUP"
rm -f "$USRMANAGE_INCOMPLETE"
: > "$USRMANAGE_AUDIT"
if (
	um_registry_del() { return 1; }
	um_with_lock um_mut_del audit 0
) >/dev/null 2>&1; then
	bad "I5 del should fail when registry_del fails"
else
	ok "I5 del fails closed on registry_del"
fi
[ -f "$USRMANAGE_INCOMPLETE" ] && grep -qx 'del:audit' "$USRMANAGE_INCOMPLETE" \
	&& ok "I5 keeps incomplete del:audit" \
	|| bad "I5 incomplete missing: $(cat "$USRMANAGE_INCOMPLETE" 2>/dev/null || echo none)"
grep -q 'result=fail' "$USRMANAGE_AUDIT" && grep -q 'reason=registry' "$USRMANAGE_AUDIT" \
	&& ok "I5 registry failure audited" \
	|| bad "I5 registry audit: $(tail -3 "$USRMANAGE_AUDIT")"
rm -f "$USRMANAGE_INCOMPLETE"
printf 'ops\n' > "$USRMANAGE_REGISTRY"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"

# V3: doctor fails closed when sudoers mode is not 0440.
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"
chmod 0644 "$USRMANAGE_SUDOERS"
_doc_json=$(um_doctor_checks --json 2>/dev/null) || true
echo "$_doc_json" | grep -q '"id":"sudoers","ok":false' \
	&& echo "$_doc_json" | grep -q '"severity":"error"' \
	&& echo "$_doc_json" | grep -q 'want 0440' \
	&& ok "V3 doctor rejects sudoers mode 0644" \
	|| bad "V3 doctor sudoers mode: $_doc_json"
chmod 0440 "$USRMANAGE_SUDOERS"

# --- set-policy under lock (CLI dispatch) ---
CLI="$ROOT/openwrt-feed/usrmanage/files/usr/sbin/usrmanage"
grep -q 'um_with_lock um_policy_save' "$CLI" \
	&& ok "set-policy wraps um_policy_save in um_with_lock" \
	|| bad "set-policy missing um_with_lock um_policy_save"

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
grep -q 'arg3=--role' "$USRMANAGE_STUB_LOG" && ok "rpcd set_role --role" || bad "rpcd set_role --role: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg4=readonly' "$USRMANAGE_STUB_LOG" && ok "rpcd set_role role value" || bad "rpcd set_role role value"

rm -f "$USRMANAGE_STUB_LOG"
sh "$RPCD" call add '{"name":"newuser","role":"readonly","password":"LabPass1!"}' >/dev/null
grep -q 'arg1=add' "$USRMANAGE_STUB_LOG" && ok "rpcd add cmd" || bad "rpcd add cmd"
grep -q 'arg3=--role' "$USRMANAGE_STUB_LOG" && ok "rpcd add --role" || bad "rpcd add --role: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg5=--password-fd' "$USRMANAGE_STUB_LOG" && ok "rpcd add --password-fd" || bad "rpcd add password-fd flag: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg6=0' "$USRMANAGE_STUB_LOG" && ok "rpcd add password-fd 0" || bad "rpcd add fd number"
grep -q 'stdin=nonempty' "$USRMANAGE_STUB_LOG" && ok "rpcd add password on stdin" || bad "rpcd add stdin"
# Password must not appear in stub argv log
grep -F 'LabPass1!' "$USRMANAGE_STUB_LOG" && bad "password leaked into stub log" || ok "password not in stub argv log"

rm -f "$USRMANAGE_STUB_LOG"
sh "$RPCD" call set_luci_login '{"name":"ops","enable":true}' >/dev/null
grep -q 'arg1=set-luci-login' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login → set-luci-login" || bad "rpcd set_luci_login cmd: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg2=ops' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login name" || bad "rpcd set_luci_login name"
grep -q 'arg3=--enable' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login --enable" || bad "rpcd set_luci_login enable: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg4=--json' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login --json" || bad "rpcd set_luci_login --json"
grep -E 'arg[0-9]+=--password' "$USRMANAGE_STUB_LOG" && bad "set_luci_login must not pass password" || ok "rpcd set_luci_login no password argv"

rm -f "$USRMANAGE_STUB_LOG"
sh "$RPCD" call set_luci_login '{"name":"ops","mode":"enable","scope":"full"}' >/dev/null
grep -q 'arg3=--enable' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login scope enable" || bad "rpcd scope enable: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg4=--scope' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login --scope" || bad "rpcd --scope: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg5=full' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login scope full" || bad "rpcd scope value: $(cat "$USRMANAGE_STUB_LOG")"

rm -f "$USRMANAGE_STUB_LOG"
sh "$RPCD" call add '{"name":"newadmin","role":"admin","password":"LabPass1!","luci_login":true,"scope":"full"}' >/dev/null
grep -q 'arg1=add' "$USRMANAGE_STUB_LOG" && ok "rpcd add luci+scope cmd" || bad "rpcd add luci+scope cmd: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg5=--luci-login' "$USRMANAGE_STUB_LOG" && ok "rpcd add --luci-login" || bad "rpcd add luci-login: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg6=--scope' "$USRMANAGE_STUB_LOG" && ok "rpcd add --scope" || bad "rpcd add --scope: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg7=full' "$USRMANAGE_STUB_LOG" && ok "rpcd add scope full" || bad "rpcd add scope value: $(cat "$USRMANAGE_STUB_LOG")"
grep -F 'LabPass1!' "$USRMANAGE_STUB_LOG" && bad "add+scope password leaked into stub log" || ok "add+scope password not in stub argv"

rm -f "$USRMANAGE_STUB_LOG"
sh "$RPCD" call set_luci_login '{"name":"ops","enable":false}' >/dev/null
grep -q 'arg1=set-luci-login' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login disable cmd" || bad "rpcd disable cmd: $(cat "$USRMANAGE_STUB_LOG")"
grep -q 'arg3=--disable' "$USRMANAGE_STUB_LOG" && ok "rpcd set_luci_login --disable" || bad "rpcd set_luci_login disable: $(cat "$USRMANAGE_STUB_LOG")"
grep -E 'arg[0-9]+=--password' "$USRMANAGE_STUB_LOG" && bad "disable must not pass password" || ok "rpcd disable no password argv"

# jsonfilter required when missing from PATH (keep /bin for sh builtins' external helpers)
mv "$TMP/bin/jsonfilter" "$TMP/bin/jsonfilter.bak"
out=$(sh "$RPCD" call list '{}' 2>/dev/null) || true
mv "$TMP/bin/jsonfilter.bak" "$TMP/bin/jsonfilter"
echo "$out" | grep -q 'jsonfilter_required' && ok "rpcd jsonfilter_required" || bad "rpcd missing jsonfilter: $out"

[ "$fail" = "0" ] || exit 1
echo "ALL MUTATOR/LOCK/RPCD TESTS PASSED"
