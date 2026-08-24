#!/bin/sh
# Host tests for the rpcd `show` write-ACL gate (issue #158).
#
# `usrmanage show` reveals uid/gid/home/shell for any existing user and
# distinguishes existence via not_found. Read ACL grants `show` to
# diagnostic/readonly sessions, so the method must run ONLY for sessions
# holding the usrmanage WRITE acl; every other case fails closed without
# invoking the CLI. Verified behaviorally through the rpcd plugin with
# shimmed ubus/jsonfilter/CLI.
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

SID=0123456789abcdef
FULLPATH="$TMP/bin:$TMP/jbin:$PATH"
NOUBUSPATH="$TMP/jbin:/bin"

_out() {
	FAKE_ACCESS="$1" RPC_SESSION="$2" PATH="$3" \
		sh "$RPCD" call show '{"name":"root"}'
}

# 1. Write ACL present -> show forwarded to CLI.
: > "$FAKE_CLI_LOG"
_out true "$SID" "$FULLPATH" >/dev/null || true
grep -q 'show' "$FAKE_CLI_LOG" && ok "write ACL: show forwarded" || bad "write ACL: CLI not invoked"

# 2. Read-only session -> fail closed (no CLI, access_denied).
: > "$FAKE_CLI_LOG"
_resp=$(_out false "$SID" "$FULLPATH")
[ -s "$FAKE_CLI_LOG" ] && bad "readonly: CLI invoked" || ok "readonly: CLI not invoked"
printf '%s' "$_resp" | grep -q 'access_denied' && ok "readonly: access_denied" || bad "readonly: missing access_denied ($_resp)"

# 3. No ubus on PATH -> fail closed.
if PATH="$NOUBUSPATH" command -v ubus >/dev/null 2>&1; then
	bad "no-ubus: allowlist PATH still resolves ubus"
fi
: > "$FAKE_CLI_LOG"
_resp=$(RPC_SESSION="$SID" PATH="$NOUBUSPATH" \
	sh "$RPCD" call show '{"name":"root"}')
[ -s "$FAKE_CLI_LOG" ] && bad "no-ubus: CLI invoked" || ok "no-ubus: CLI not invoked"
printf '%s' "$_resp" | grep -q 'access_denied' && ok "no-ubus: access_denied" || bad "no-ubus: missing access_denied ($_resp)"

# 4. Malformed RPC_SESSION -> fail closed.
: > "$FAKE_CLI_LOG"
_resp=$(FAKE_ACCESS=true RPC_SESSION=';reboot' PATH="$FULLPATH" \
	sh "$RPCD" call show '{"name":"root"}')
[ -s "$FAKE_CLI_LOG" ] && bad "bad sid: CLI invoked" || ok "bad sid: CLI not invoked"
printf '%s' "$_resp" | grep -q 'access_denied' && ok "bad sid: access_denied" || bad "bad sid: missing access_denied ($_resp)"

[ "$fail" = "0" ] || exit 1
echo "rpcd show ACL gate tests: ok"
