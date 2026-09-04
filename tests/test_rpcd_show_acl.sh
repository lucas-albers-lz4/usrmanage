#!/bin/sh
# Host tests for the rpcd `show` write-ACL gate (issue #158 / S1 #168).
#
# `usrmanage show` reveals uid/gid/home/shell for any existing user and
# distinguishes existence via not_found. Read ACL grants `show` to
# diagnostic/readonly sessions, so the method must run ONLY for sessions
# holding the usrmanage WRITE acl; every other case fails closed without
# invoking the CLI. SID comes from ubus_rpc_session in the request body.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
RPCD="$ROOT/openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok() { echo "ok: $1"; }
bad() { echo "BAD: $1"; fail=1; }

mkdir -p "$TMP/bin" "$TMP/jbin"

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
case "$4" in
	*'"ubus_rpc_session":"0123456789abcdef0123456789abcdef"'*) ;;
	*) echo "unexpected SID in session access payload: $4" >&2; exit 1 ;;
esac
case "$FAKE_ACCESS" in
	true) printf '%s\n' '{"access":true}' ;;
	*) printf '%s\n' '{"access":false}' ;;
esac
STUB
chmod +x "$TMP/bin/ubus"

cat > "$TMP/jbin/jsonfilter" <<'STUB'
#!/bin/sh
_key=$(printf '%s' "$*" | sed -n 's/.*@\.\([A-Za-z_]*\).*/\1/p')
[ -n "$_key" ] || exit 0
sed -n "s/.*\"$_key\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^,}\"]*\)\"\{0,1\}.*/\1/p"
STUB
chmod +x "$TMP/jbin/jsonfilter"

cat > "$TMP/bin/usrmanage-stub" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" > "$FAKE_CLI_LOG"
printf '%s\n' '{"ok":true,"user":{"name":"root"}}'
STUB
chmod +x "$TMP/bin/usrmanage-stub"
export USRMANAGE_BIN="$TMP/bin/usrmanage-stub"
export FAKE_CLI_LOG="$TMP/cli-args.log"

SID=0123456789abcdef0123456789abcdef
SHORT=0123456789abcdef
FULLPATH="$TMP/bin:$TMP/jbin:$PATH"
NOUBUSPATH="$TMP/jbin:/bin"

_out() {
	# _out <FAKE_ACCESS> <json-body> [PATH]
	FAKE_ACCESS="$1" PATH="${3:-$FULLPATH}" \
		sh "$RPCD" call show "$2"
}

# 1. Write ACL present -> show forwarded to CLI.
: > "$FAKE_CLI_LOG"
_out true "{\"name\":\"root\",\"ubus_rpc_session\":\"${SID}\"}" >/dev/null || true
grep -q 'show' "$FAKE_CLI_LOG" && ok "write ACL: show forwarded" || bad "write ACL: CLI not invoked"

# 2. Read-only session -> fail closed (no CLI, access_denied).
: > "$FAKE_CLI_LOG"
_resp=$(_out false "{\"name\":\"root\",\"ubus_rpc_session\":\"${SID}\"}")
[ -s "$FAKE_CLI_LOG" ] && bad "readonly: CLI invoked" || ok "readonly: CLI not invoked"
printf '%s' "$_resp" | grep -q 'access_denied' && ok "readonly: access_denied" || bad "readonly: missing access_denied ($_resp)"

# 3. No ubus on PATH -> fail closed.
if PATH="$NOUBUSPATH" command -v ubus >/dev/null 2>&1; then
	bad "no-ubus: allowlist PATH still resolves ubus"
fi
: > "$FAKE_CLI_LOG"
_resp=$(_out true "{\"name\":\"root\",\"ubus_rpc_session\":\"${SID}\"}" "$NOUBUSPATH")
[ -s "$FAKE_CLI_LOG" ] && bad "no-ubus: CLI invoked" || ok "no-ubus: CLI not invoked"
printf '%s' "$_resp" | grep -q 'access_denied' && ok "no-ubus: access_denied" || bad "no-ubus: missing access_denied ($_resp)"

# 4. Malformed SID in body -> fail closed.
: > "$FAKE_CLI_LOG"
_resp=$(_out true '{"name":"root","ubus_rpc_session":";reboot"}')
[ -s "$FAKE_CLI_LOG" ] && bad "bad sid: CLI invoked" || ok "bad sid: CLI not invoked"
printf '%s' "$_resp" | grep -q 'access_denied' && ok "bad sid: access_denied" || bad "bad sid: missing access_denied ($_resp)"

# 5. Missing body SID (env alone) -> fail closed.
: > "$FAKE_CLI_LOG"
_resp=$(FAKE_ACCESS=true RPC_SESSION="$SID" PATH="$FULLPATH" \
	sh "$RPCD" call show '{"name":"root"}')
[ -s "$FAKE_CLI_LOG" ] && bad "no body sid: CLI invoked" || ok "no body sid: CLI not invoked"
printf '%s' "$_resp" | grep -q 'access_denied' && ok "no body sid: access_denied" || bad "no body sid: missing access_denied ($_resp)"

# 6. Wrong length (16 hex) -> fail closed.
: > "$FAKE_CLI_LOG"
_resp=$(_out true "{\"name\":\"root\",\"ubus_rpc_session\":\"${SHORT}\"}")
[ -s "$FAKE_CLI_LOG" ] && bad "short sid: CLI invoked" || ok "short sid: CLI not invoked"
printf '%s' "$_resp" | grep -q 'access_denied' && ok "short sid: access_denied" || bad "short sid: missing access_denied ($_resp)"

[ "$fail" = "0" ] || exit 1
echo "rpcd show ACL gate tests: ok"
