#!/bin/sh
# Doctor severity + BusyBox-safe sudoers mode probe.
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
export USRMANAGE_SRC=cli
export USRMANAGE_ACTOR=testhost
export USRMANAGE_TEST_OVERRIDES=1

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$TMP/bin" "$TMP/home"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
printf 'root:x:0:0:root:/root:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\n' > "$USRMANAGE_GROUP"
: > "$USRMANAGE_REGISTRY"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"
chmod 0440 "$USRMANAGE_SUDOERS"
printf 'config rpcd\n' > "$USRMANAGE_RPCD_CONFIG"

# shellcheck disable=SC1090
. "$LIB"
. "$ROOT/tests/lib.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

json_field() {
	# Tiny extractor for doctor --json (no jq required).
	printf '%s' "$1" | tr -d '\n'
}

# --- clean install: wheel warn only, top-level ok true, sudoers ok via find/stat ---
_doc=$(um_doctor_checks --json 2>/dev/null) || true
echo "$_doc" | grep -q '"ok":true' \
	&& ok "clean install doctor top-level ok true" \
	|| bad "clean install ok: $_doc"
echo "$_doc" | grep -q '"id":"wheel","ok":false,"severity":"warn"' \
	&& ok "clean install wheel is warn" \
	|| bad "clean install wheel: $_doc"
echo "$_doc" | grep -q '"id":"sudoers","ok":true' \
	&& ok "clean install sudoers ok at 0440" \
	|| bad "clean install sudoers: $_doc"

# --- wheel missing + live managed user → error ---
printf 'alice:x:1001:1001:alice:%s/alice:/bin/ash\n' "$TMP/home" >> "$USRMANAGE_PASSWD"
printf 'alice:::0:99999:7:::\n' >> "$USRMANAGE_SHADOW"
printf 'alice\n' > "$USRMANAGE_REGISTRY"
_doc=$(um_doctor_checks --json 2>/dev/null) || true
echo "$_doc" | grep -q '"ok":false' \
	&& echo "$_doc" | grep -q '"id":"wheel","ok":false,"severity":"error"' \
	&& ok "wheel missing with live user is error" \
	|| bad "live user wheel: $_doc"

# --- stale registry only (no passwd) → warn, ok true (if sudoers still good) ---
printf 'root:x:0:0:root:/root:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'ghost\n' > "$USRMANAGE_REGISTRY"
_doc=$(um_doctor_checks --json 2>/dev/null) || true
echo "$_doc" | grep -q '"ok":true' \
	&& echo "$_doc" | grep -q '"id":"wheel","ok":false,"severity":"warn"' \
	&& ok "stale registry-only keeps wheel warn" \
	|| bad "stale registry wheel: $_doc"
: > "$USRMANAGE_REGISTRY"

# --- V3: 0644 still error ---
chmod 0644 "$USRMANAGE_SUDOERS"
_doc=$(um_doctor_checks --json 2>/dev/null) || true
echo "$_doc" | grep -q '"id":"sudoers","ok":false' \
	&& echo "$_doc" | grep -q '"severity":"error"' \
	&& echo "$_doc" | grep -q 'want 0440' \
	&& ok "V3 sudoers 0644 is error" \
	|| bad "V3 0644: $_doc"
chmod 0440 "$USRMANAGE_SUDOERS"

# --- symlink sudoers → error (before -f follows) ---
rm -f "$USRMANAGE_SUDOERS"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$TMP/sudoers.real"
chmod 0440 "$TMP/sudoers.real"
ln -s "$TMP/sudoers.real" "$USRMANAGE_SUDOERS"
_doc=$(um_doctor_checks --json 2>/dev/null) || true
echo "$_doc" | grep -q '"id":"sudoers","ok":false' \
	&& echo "$_doc" | grep -qi symlink \
	&& ok "symlink sudoers rejected" \
	|| bad "symlink sudoers: $_doc"
rm -f "$USRMANAGE_SUDOERS"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"
chmod 0440 "$USRMANAGE_SUDOERS"

# --- BusyBox-ish: hide real stat, provide garbage-stat then find path ---
# Scope PATH override to a subshell so tests/lib.sh stat_mode still works later.
(
	_shim="$TMP/shim"
	mkdir -p "$_shim"
	# No stat on PATH — force find -perm fallback.
	cat > "$_shim/busybox" <<'EOF'
#!/bin/sh
echo "busybox: applet not found" >&2
exit 1
EOF
	chmod +x "$_shim/busybox"
	# Keep essential tools reachable; put shim first so a `stat` here wins.
	cat > "$_shim/stat" <<'EOF'
#!/bin/sh
# Missing/broken BusyBox stub: always fail.
exit 1
EOF
	chmod +x "$_shim/stat"
	# Provide find/id/chmod etc via original PATH after shim.
	export PATH="$_shim:/usr/bin:/bin:/usr/sbin:/sbin"
	# Re-source lib under this PATH for um_file_mode_octal / doctor.
	# shellcheck disable=SC1090
	. "$LIB"
	_doc=$(um_doctor_checks --json 2>/dev/null) || true
	echo "$_doc" | grep -q '"id":"sudoers","ok":true' \
		&& echo "$_doc" | grep -q '"ok":true' \
		&& ok "stat stub: find -perm 440 accepts 0440" \
		|| bad "stat stub find: $_doc"
)

# --- garbage stat output must not be accepted; fall through to find ---
(
	_shim="$TMP/shim2"
	mkdir -p "$_shim"
	cat > "$_shim/stat" <<'EOF'
#!/bin/sh
# Pretend success with non-octal garbage (lab BusyBox-class failure mode).
printf 'not-a-mode\n'
exit 0
EOF
	chmod +x "$_shim/stat"
	export PATH="$_shim:/usr/bin:/bin:/usr/sbin:/sbin"
	# shellcheck disable=SC1090
	. "$LIB"
	_doc=$(um_doctor_checks --json 2>/dev/null) || true
	echo "$_doc" | grep -q '"id":"sudoers","ok":true' \
		&& ok "garbage stat falls through to find -perm" \
		|| bad "garbage stat: $_doc"
)

# --- human doctor lists failing checks ---
_human=$(um_doctor_checks 2>/dev/null) || true
echo "$_human" | grep -q 'warn wheel:' \
	&& ok "human doctor lists wheel warn" \
	|| bad "human doctor: $_human"

[ "$fail" -eq 0 ] || exit 1
echo "doctor tests passed"
