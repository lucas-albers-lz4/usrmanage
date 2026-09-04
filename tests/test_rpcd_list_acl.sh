#!/bin/sh
# Host tests for the rpcd `list` write-ACL gate (issue #149 / S1 #168).
#
# `usrmanage list --all` enumerates every passwd row >= UID floor. The read
# ACL grants `list` to diagnostic/readonly sessions, so `all` must be honored
# ONLY for sessions holding the usrmanage WRITE acl; every other case fails
# closed to the plain managed-user list. SID is taken from the request body
# field ubus_rpc_session (32 hex), not from RPC_SESSION env.
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

# Real OpenWrt SIDs are 32 hex; shorter env-era fixtures must fail closed (S1).
SID=0123456789abcdef0123456789abcdef
SHORT=0123456789abcdef
FULLPATH="$TMP/bin:$TMP/jbin:$PATH"
# Allowlist PATH for the missing-ubus case (CodeRabbit r2 fold): only the
# jsonfilter shim + /bin, so the result cannot depend on whether the host
# happens to have ubus installed. The assertion below makes a leak loud.
NOUBUSPATH="$TMP/jbin:/bin"

_call_list() {
	# _call_list <json-body>
	PATH="$FULLPATH" FAKE_ACCESS="${FAKE_ACCESS:-true}" \
		sh "$RPCD" call list "$1" >/dev/null || true
}

# 1. Write ACL present (access:true) + body SID -> all honored.
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=true _call_list "{\"all\":true,\"ubus_rpc_session\":\"${SID}\"}"
grep -q -- '--all' "$FAKE_CLI_LOG" && ok "write ACL: --all honored" || bad "write ACL: --all missing"

# 2. Read-only session (access:false) -> all stripped (no --all).
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=false _call_list "{\"all\":true,\"ubus_rpc_session\":\"${SID}\"}"
[ -s "$FAKE_CLI_LOG" ] && ok "readonly: plain-list CLI path ran" || bad "readonly: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "readonly: --all still passed" || ok "readonly: --all stripped"

# 3. No ubus on PATH -> fail closed (no --all).
if PATH="$NOUBUSPATH" command -v ubus >/dev/null 2>&1; then
	bad "no-ubus: allowlist PATH still resolves ubus"
fi
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=true PATH="$NOUBUSPATH" \
	sh "$RPCD" call list "{\"all\":true,\"ubus_rpc_session\":\"${SID}\"}" >/dev/null || true
[ -s "$FAKE_CLI_LOG" ] && ok "no-ubus: plain-list CLI path ran" || bad "no-ubus: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "no-ubus: --all passed" || ok "no-ubus: fail closed"

# 4. Malformed SID in body -> fail closed (no --all).
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=true _call_list '{"all":true,"ubus_rpc_session":";reboot"}'
[ -s "$FAKE_CLI_LOG" ] && ok "bad sid: plain-list CLI path ran" || bad "bad sid: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "bad sid: --all passed" || ok "bad sid: fail closed"

# 5. Missing SID -> fail closed (env RPC_SESSION ignored).
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=true RPC_SESSION="$SID" _call_list '{"all":true}'
[ -s "$FAKE_CLI_LOG" ] && ok "no body sid: plain-list CLI path ran" || bad "no body sid: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "no body sid: --all passed (env leak?)" || ok "no body sid: fail closed"

# 6. Wrong length (16 hex) -> fail closed.
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=true _call_list "{\"all\":true,\"ubus_rpc_session\":\"${SHORT}\"}"
[ -s "$FAKE_CLI_LOG" ] && ok "short sid: plain-list CLI path ran" || bad "short sid: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "short sid: --all passed" || ok "short sid: fail closed"

# 7. Plain list (all:false) unchanged -> no --all.
: > "$FAKE_CLI_LOG"
FAKE_ACCESS=true _call_list "{\"all\":false,\"ubus_rpc_session\":\"${SID}\"}"
[ -s "$FAKE_CLI_LOG" ] && ok "all:false: plain-list CLI path ran" || bad "all:false: CLI never invoked"
grep -q -- '--all' "$FAKE_CLI_LOG" && bad "all:false: --all passed" || ok "all:false: plain list"

[ "$fail" = "0" ] || exit 1
echo "rpcd list ACL gate tests: ok"
