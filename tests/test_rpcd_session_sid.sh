#!/bin/sh
# Host tests for body-derived SID → actor attribution (S1 #168).
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
	"call session access")
		printf '%s\n' '{"access":true}'
		exit 0
		;;
	"call session get")
		printf '%s\n' '{"values":{"username":"adminops"}}'
		exit 0
		;;
	*) echo "unexpected ubus args: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/ubus"

cat > "$TMP/jbin/jsonfilter" <<'STUB'
#!/bin/sh
# Support @.key and @.values.username
_expr=$(printf '%s' "$*" | sed -n 's/.*-e[[:space:]]*//p')
case "$_expr" in
	'@.values.username'|@.values.username)
		sed -n 's/.*"username"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
		;;
	*)
		_key=$(printf '%s' "$_expr" | sed -n 's/.*@\.\([A-Za-z_]*\).*/\1/p')
		[ -n "$_key" ] || exit 0
		sed -n "s/.*\"$_key\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^,}\"]*\)\"\{0,1\}.*/\1/p"
		;;
esac
STUB
chmod +x "$TMP/jbin/jsonfilter"

cat > "$TMP/bin/usrmanage-stub" <<'STUB'
#!/bin/sh
# Record USRMANAGE_ACTOR exported by the plugin.
printf 'actor=%s\n' "${USRMANAGE_ACTOR:-}" > "$FAKE_CLI_LOG"
printf '%s\n' '{"ok":true,"users":[]}'
STUB
chmod +x "$TMP/bin/usrmanage-stub"
export USRMANAGE_BIN="$TMP/bin/usrmanage-stub"
export FAKE_CLI_LOG="$TMP/cli-args.log"
export PATH="$TMP/bin:$TMP/jbin:$PATH"

SID=0123456789abcdef0123456789abcdef

: > "$FAKE_CLI_LOG"
# Clear harness override so body SID → session get is exercised.
unset USRMANAGE_ACTOR
sh "$RPCD" call list "{\"all\":false,\"ubus_rpc_session\":\"${SID}\"}" >/dev/null || true
grep -q 'actor=adminops' "$FAKE_CLI_LOG" && ok "body SID resolves actor=adminops" || bad "actor from SID: $(cat "$FAKE_CLI_LOG")"

: > "$FAKE_CLI_LOG"
sh "$RPCD" call list '{"all":false}' >/dev/null || true
grep -q 'actor=unknown' "$FAKE_CLI_LOG" && ok "missing SID → actor=unknown" || bad "missing SID actor: $(cat "$FAKE_CLI_LOG")"

[ "$fail" = "0" ] || exit 1
echo "rpcd session SID actor tests: ok"
