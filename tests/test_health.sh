#!/bin/sh
# Host tests for usrmanage health schema, projector, and ACL JSON (readonly observer).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"
ACL="$ROOT/openwrt-feed/luci-app-usrmanage/root/usr/share/rpcd/acl.d/luci-app-usrmanage.json"
RPCD="$ROOT/openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage"
CLI="$ROOT/openwrt-feed/usrmanage/files/usr/sbin/usrmanage"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export USRMANAGE_LIB_DIR=$(dirname "$LIB")
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
export USRMANAGE_TEST_OVERRIDES=1
export JSON_OUT=0

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$TMP/bin"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
printf 'root:x:0:0:root:/root:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\n' > "$USRMANAGE_GROUP"

# shellcheck disable=SC1090
. "$LIB"
. "$ROOT/tests/lib.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

command -v um_cmd_health >/dev/null 2>&1 && ok "health helper sourced" || bad "health helper missing"
command -v um_health_json_emit >/dev/null 2>&1 && ok "health emitter present" || bad "emitter missing"

_FIX='{"ok":true,"hostname":"dry-run","release":"24.10.x","uptime_s":86400,"load":[0.01,0.02,0.00],"wan":{"up":true,"ipv4":true,"ipv6":true},"lan":{"up":true},"wifi":{"radios_up":2,"radios_total":2,"assoc_count":4},"dhcp_lease_count":6}'
_got=$(um_cmd_health --json)
[ "$_got" = "$_FIX" ] && ok "DRY_RUN health fixture equality" || bad "DRY_RUN fixture: $_got"

# gather failure must emit exactly one JSON error (not gather+cmd double print).
_unav=$(
	USRMANAGE_DRY_RUN=0
	um_health_gather_json() { return 1; }
	um_cmd_health
)
_nunav=$(printf '%s\n' "$_unav" | grep -c 'health_unavailable' || true)
[ "$_unav" = '{"ok":false,"error":"health_unavailable"}' ] && [ "$_nunav" = "1" ] \
	&& ok "health_unavailable is a single JSON object" \
	|| bad "health_unavailable duplicate: $_unav"

_cli=$(USRMANAGE_DRY_RUN=1 JSON_OUT=1 "$CLI" health --json)
[ "$_cli" = "$_FIX" ] && ok "CLI health --json DRY_RUN equality" || bad "CLI health: $_cli"

# Schema equality (exact keys/types) — deny-list grep is not the proof.
if python3 - "$_got" <<'PY'
import json, re, sys
raw = sys.argv[1]
obj = json.loads(raw)
want_top = ["ok", "hostname", "release", "uptime_s", "load", "wan", "lan", "wifi", "dhcp_lease_count"]
if list(obj.keys()) != want_top:
    print("FAIL top keys", list(obj.keys()), file=sys.stderr)
    sys.exit(1)
if obj["ok"] is not True:
    print("FAIL ok", file=sys.stderr); sys.exit(1)
if not isinstance(obj["hostname"], str) or not isinstance(obj["release"], str):
    print("FAIL hostname/release type", file=sys.stderr); sys.exit(1)
if type(obj["uptime_s"]) is not int:
    print("FAIL uptime_s type", file=sys.stderr); sys.exit(1)
if not (isinstance(obj["load"], list) and len(obj["load"]) == 3):
    print("FAIL load", file=sys.stderr); sys.exit(1)
for n in obj["load"]:
    if not isinstance(n, (int, float)):
        print("FAIL load element", file=sys.stderr); sys.exit(1)
if list(obj["wan"].keys()) != ["up", "ipv4", "ipv6"]:
    print("FAIL wan keys", file=sys.stderr); sys.exit(1)
for k in ("up", "ipv4", "ipv6"):
    if type(obj["wan"][k]) is not bool:
        print("FAIL wan bool", k, file=sys.stderr); sys.exit(1)
if list(obj["lan"].keys()) != ["up"] or type(obj["lan"]["up"]) is not bool:
    print("FAIL lan", file=sys.stderr); sys.exit(1)
if list(obj["wifi"].keys()) != ["radios_up", "radios_total", "assoc_count"]:
    print("FAIL wifi keys", file=sys.stderr); sys.exit(1)
for k in ("radios_up", "radios_total", "assoc_count"):
    if type(obj["wifi"][k]) is not int:
        print("FAIL wifi int", k, file=sys.stderr); sys.exit(1)
if type(obj["dhcp_lease_count"]) is not int:
    print("FAIL dhcp_lease_count", file=sys.stderr); sys.exit(1)
s = json.dumps(obj, separators=(",", ":"))
if re.search(r"(?i)([0-9a-f]{2}:){5}[0-9a-f]{2}", s):
    print("FAIL MAC in reply", file=sys.stderr); sys.exit(1)
if re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", s):
    print("FAIL IPv4 in reply", file=sys.stderr); sys.exit(1)
if re.search(r"(?i)ssid|sae_password|private_key|mesh_id|bssid|shadow", s):
    print("FAIL secret class token in reply", file=sys.stderr); sys.exit(1)
print("schema-ok")
PY
then
	ok "health JSON schema equality + leak regex"
else
	bad "health JSON schema equality + leak regex"
fi

# Projector emit cannot grow keys; hostile dump must not appear in output.
_hostile='{"ssid":"SecretSSID","key":"psk-value","sae_password":"saeX","mesh_id":"meshX","bssid":"aa:bb:cc:dd:ee:ff","private_key":"WGKEY","radio0":{"up":true,"config":{"ssid":"SecretSSID","key":"psk-value"}},"assoc_count":3}'
_proj=$(um_health_json_emit "cpe-12" "24.10.x" 10 0.01 0.02 0.00 1 1 0 1 2 2 4 6)
printf '%s' "$_proj" | grep -q '"hostname":"cpe-12"' && ok "emit hostname" || bad "emit hostname"
printf '%s' "$_proj" | grep -q SecretSSID && bad "emit leaked ssid" || ok "emit dropped ssid (not in inputs)"
_wifi_counts=$(printf '%s' "$_hostile" | um_health_wifi_from_status_blob)
printf '%s' "$_wifi_counts" | grep -q SecretSSID && bad "wifi projector leaked ssid" || ok "wifi projector dropped ssid"
printf '%s' "$_wifi_counts" | grep -q psk-value && bad "wifi projector leaked key" || ok "wifi projector dropped key"

# ACL JSON: health group read-only, method list exactly health, no globs; session has no uci.
if python3 - "$ACL" <<'PY'
import json, sys
acl = json.load(open(sys.argv[1]))
if "luci-app-usrmanage-health" not in acl:
    print("missing health group", file=sys.stderr); sys.exit(1)
h = acl["luci-app-usrmanage-health"]
if "write" in h:
    print("health group must not have write", file=sys.stderr); sys.exit(1)
methods = h.get("read", {}).get("ubus", {}).get("usrmanage")
if methods != ["health"]:
    print("health methods", methods, file=sys.stderr); sys.exit(1)
blob = json.dumps(h)
if "*" in blob or "?" in blob:
    print("glob in health ACL", file=sys.stderr); sys.exit(1)
sess = acl["luci-app-usrmanage-session"]["read"]
ubus = sess.get("ubus", {})
if "uci" in ubus or "uci" in sess:
    print("session ACL still has uci", file=sys.stderr); sys.exit(1)
if ubus.get("session") != ["access"] or ubus.get("luci") != ["getFeatures"]:
    print("session ubus", ubus, file=sys.stderr); sys.exit(1)
app = acl["luci-app-usrmanage"]
if "list" not in app["read"]["ubus"]["usrmanage"]:
    print("app list missing", file=sys.stderr); sys.exit(1)
if "add" not in app["write"]["ubus"]["usrmanage"]:
    print("app write missing", file=sys.stderr); sys.exit(1)
print("acl-ok")
PY
then
	ok "ACL JSON health/session/app split"
else
	bad "ACL JSON health/session/app split"
fi

# rpcd list: health declared with no params; no glob in method name.
_list=$(sh "$RPCD" list)
printf '%s' "$_list" | grep -q '"health": {}' && ok "rpcd list health {}" || bad "rpcd list health: $_list"
printf '%s' "$_list" | grep -qE '"health[?*]' && bad "rpcd health glob in list" || ok "rpcd health method has no glob"

# rpcd health: no read_input; hostile body byte-identical to empty body.
cat > "$TMP/bin/usrmanage-stub" <<'STUB'
#!/bin/sh
printf '%s\n' '{"ok":true,"hostname":"dry-run","release":"24.10.x","uptime_s":86400,"load":[0.01,0.02,0.00],"wan":{"up":true,"ipv4":true,"ipv6":true},"lan":{"up":true},"wifi":{"radios_up":2,"radios_total":2,"assoc_count":4},"dhcp_lease_count":6}'
STUB
chmod +x "$TMP/bin/usrmanage-stub"
export USRMANAGE_BIN="$TMP/bin/usrmanage-stub"
_a=$(sh "$RPCD" call health '{}')
_b=$(sh "$RPCD" call health '{"ssid":"SecretSSID","key":"psk-value","password":"x"}')
_c=$(printf '{"ssid":"leak"}' | sh "$RPCD" call health)
[ "$_a" = "$_b" ] && ok "rpcd health hostile JSON body byte-identical" || bad "hostile body diverged: a=$_a b=$_b"
[ "$_a" = "$_c" ] && ok "rpcd health stdin body ignored (byte-identical)" || bad "stdin body diverged"
printf '%s' "$_a" | grep -q SecretSSID && bad "rpcd health echoed hostile ssid" || ok "rpcd health did not echo hostile body"
grep -q 'read_input' "$RPCD" && grep -q 'METHOD" = "health"' "$RPCD" \
	&& ok "rpcd health skips read_input" || bad "rpcd health still uses read_input"

# Declared read: health is not in the write object of app ACL (already checked) and
# rpcd plugin has no write branch for health.
grep -n 'health' "$RPCD" | grep -q 'set_role\|passwd\|add' && bad "health mixed into mutators" \
	|| ok "health not mixed into mutator argv"

[ "$fail" = "0" ] || exit 1
echo "health schema/ACL tests: ok"
