#!/bin/sh
# Host tests for the rpcd `list` write-ACL gate (issue #149).
#
# `usrmanage list --all` enumerates every passwd row >= UID floor. The read
# ACL grants `list` to diagnostic/readonly sessions, so `all` must be honored
# ONLY for sessions holding the usrmanage WRITE acl; every other case fails
# closed to the plain managed-user list. Verified behaviorally through the
# rpcd plugin with shimmed ubus/jsonfilter/CLI.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RPCD="$ROOT/openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok() { echo "ok: $1"; }
bad() { echo "BAD: $1"; fail=1; }

mkdir -p "$TMP/bin" "$TMP/jbin"

# Fake ubus: answers `session access` for the usrmanage.add request per
# FAKE_ACCESS. Requires the EXACT probe shape — `call session access` on the
# usrmanage.add method — so a regression in the plugin's probe (wrong method,
# wrong object/function) is caught by these tests instead of silently
# answered.
cat > "$TMP/bin/ubus" <<'STUB'
#!/bin/sh
case "$1 $2 $3" in
	"call session access") ;;
	*) echo "unexpected ubus args: $*" >&2; exit 1 ;;
esac
case "$4" in
	*'"object":"usrmanage"'*'"function":"add"'*) ;;
	*) echo "unexpected session access payload: $4" >&2; exit 1 ;;
esac
case "$FAKE_ACCESS" in
	true) printf '%s\n' '{"access":true}' ;;
	*) printf '%s\n' '{"access":false}' ;;
esac
STUB
chmod +x "$TMP/bin/ubus"

# Minimal jsonfilter shim: extract one @.key from single-line JSON on stdin.
# sed-based (not a read loop) so input WITHOUT a trailing newline still works
# — the plugin pipes `printf '%s'` (no newline) into jsonfilter.
# Lives in its own dir so the no-ubus case can drop only the ubus shim.
cat > "$TMP/jbin/jsonfilter" <<'STUB'
#!/bin/sh
_key=$(printf '%s' "$*" | sed -n 's/.*@\.\([A-Za-z_]*\).*/\1/p')
[ -n "$_key" ] || exit 0
sed -n "s/.*\"$_key\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^,}\"]*\)\"\{0,1\}.*/\1/p"
STUB
chmod +x "$TMP/jbin/jsonfilter"

# Fake usrmanage CLI: records whether --all was passed.
cat > "$TMP/bin/usrmanage-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$FAKE_CLI_LOG"
printf '%s\n' '{"ok":true,"users":[]}'
STUB
chmod +x "$TMP/bin/usrmanage-stub"
export USRMANAGE_BIN="$TMP/bin/usrmanage-stub"
export FAKE_CLI_LOG="$TMP/cli-args.log"

SID=0123456789abcdef
FULLPATH="$TMP/bin:$TMP/jbin:$PATH"
# PATH without the fake-ubus dir (jsonfilter shim stays).
NOUBUSPATH="$TMP/jbin:$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^$TMP/bin$" | paste -sd: -)"

# 1. Write ACL present (access:true) -> all honored (--all passed to CLI).
FAKE_ACCESS=true RPC_SESSION=$SID PATH="$FULLPATH" \
	sh "$RPCD" call list '{"all":true}' >/dev/null || true
grep -q -- '--all' "$FAKE_CLI_LOG" && ok "write ACL: --all honored" || bad "write ACL: --all missing"

# 2. Read-only session (access:false) -> all stripped (no --all).
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=false RPC_SESSION=$SID PATH="$FULLPATH" \
	sh "$RPCD" call list '{"all":true}' >/dev/null || true
[ -s "$FAKE_CLI_LOG" ] && ok "readonly: plain-list CLI path ran" || bad "readonly: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "readonly: --all still passed" || ok "readonly: --all stripped"

# 3. No ubus on PATH -> fail closed (no --all).
: > "$FAKE_CLI_LOG"
RPC_SESSION=$SID PATH="$NOUBUSPATH" \
	sh "$RPCD" call list '{"all":true}' >/dev/null || true
[ -s "$FAKE_CLI_LOG" ] && ok "no-ubus: plain-list CLI path ran" || bad "no-ubus: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "no-ubus: --all passed" || ok "no-ubus: fail closed"

# 4. Malformed RPC_SESSION -> fail closed (no --all).
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=true RPC_SESSION=';reboot' PATH="$FULLPATH" \
	sh "$RPCD" call list '{"all":true}' >/dev/null || true
[ -s "$FAKE_CLI_LOG" ] && ok "bad sid: plain-list CLI path ran" || bad "bad sid: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "bad sid: --all passed" || ok "bad sid: fail closed"

# 5. Plain list (all:false) unchanged -> no --all.
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=true RPC_SESSION=$SID PATH="$FULLPATH" \
	sh "$RPCD" call list '{"all":false}' >/dev/null || true
[ -s "$FAKE_CLI_LOG" ] && ok "all:false: plain-list CLI path ran" || bad "all:false: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "all:false: --all passed" || ok "all:false: plain list"

[ "$fail" = "0" ] || exit 1
echo "rpcd list ACL gate tests: ok"
