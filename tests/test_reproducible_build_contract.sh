#!/usr/bin/env bash
# Host contracts for reproducibility error propagation and target-arch hashing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/sdk-matrix.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/verify-reproducible-build.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

make_ipk_fixture() {
	local name=$1 version=$2 output=$3 description=${4:-} stage
	stage="$TMP/ipk-$name"
	rm -rf "$stage"
	mkdir -p "$stage/control"
	printf 'Package: %s\nVersion: %s\nArchitecture: all\n' "$name" "$version" >"$stage/control/control"
	[ -z "$description" ] || printf 'Description: %s\n' "$description" >>"$stage/control/control"
	printf '2.0\n' >"$stage/debian-binary"
	tar -czf "$stage/control.tar.gz" -C "$stage/control" .
	tar -czf "$output" -C "$stage" debian-binary control.tar.gz
}

expected_usr=$(sdk_matrix_expected_package_version usrmanage)
expected_luci=$(sdk_matrix_expected_package_version luci-app-usrmanage)
VERIFY_ROOT="$TMP/verify-root"
mkdir -p "$VERIFY_ROOT/out/x86_64/24.10.8/usrmanage" \
	"$VERIFY_ROOT/out/aarch64_generic/24.10.8/usrmanage" "$VERIFY_ROOT/scripts"
make_ipk_fixture usrmanage "$expected_usr" "$TMP/usrmanage.ipk"
make_ipk_fixture luci-app-usrmanage "$expected_luci" "$TMP/luci.ipk"
for arch in x86_64 aarch64_generic; do
	cp "$TMP/usrmanage.ipk" "$VERIFY_ROOT/out/$arch/24.10.8/usrmanage/usrmanage_${expected_usr}_all.ipk"
	cp "$TMP/luci.ipk" "$VERIFY_ROOT/out/$arch/24.10.8/usrmanage/luci-app-usrmanage_${expected_luci}_all.ipk"
done
ROOT="$VERIFY_ROOT"
SDK_MATRIX_VERSION=24.10
SDK_MATRIX_VERSION_LABEL=24.10.8
SDK_MATRIX_PACKAGE_ARCH=x86_64
_x86_before=$(artifact_shas 24.10.8)
SDK_MATRIX_PACKAGE_ARCH=aarch64_generic
_arm_before=$(artifact_shas 24.10.8)
make_ipk_fixture usrmanage "$expected_usr" "$TMP/arm-changed.ipk" changed-payload
cp "$TMP/arm-changed.ipk" "$VERIFY_ROOT/out/aarch64_generic/24.10.8/usrmanage/usrmanage_${expected_usr}_all.ipk"
_arm_after=$(artifact_shas 24.10.8)
SDK_MATRIX_PACKAGE_ARCH=x86_64
_x86_after=$(artifact_shas 24.10.8)
if [[ "$_arm_before" != "$_arm_after" && "$_x86_before" == "$_x86_after" ]]; then
	ok "repro hashes the selected ARM output, not cached x86"
else
	bad "repro architecture selection is incorrect"
fi

# The 25.12 APK glob must hash both required package names as well.
sdk_matrix_read_apk_metadata() { cat "${1}.metadata.json"; }
mkdir -p "$VERIFY_ROOT/out/x86_64/25.12.5/usrmanage"
for package in usrmanage luci-app-usrmanage; do
	if [ "$package" = usrmanage ]; then version=$expected_usr; else version=$expected_luci; fi
	apk="$VERIFY_ROOT/out/x86_64/25.12.5/usrmanage/${package}-${version}.apk"
	printf 'APK fixture %s\n' "$package" >"$apk"
	printf '{"info":{"name":"%s","version":"%s","arch":"noarch"}}\n' \
		"$package" "$version" >"${apk}.metadata.json"
done
SDK_MATRIX_VERSION=25.12
SDK_MATRIX_VERSION_LABEL=25.12.5
SDK_MATRIX_PACKAGE_ARCH=x86_64
_apk_hashes=$(artifact_shas 25.12.5)
_apk_count=$(printf '%s\n' "$_apk_hashes" | wc -l | tr -d ' ')
if [ "$_apk_count" -eq 2 ] \
	&& printf '%s\n' "$_apk_hashes" | grep -q "usrmanage-${expected_usr}\\.apk" \
	&& printf '%s\n' "$_apk_hashes" | grep -q "luci-app-usrmanage-${expected_luci}\\.apk"; then
	ok "25.12 reproducibility hashes both APK packages"
else
	bad "25.12 reproducibility did not hash both APK packages"
fi

# Override the expensive build boundaries; keep verifier control flow real.
# shellcheck disable=SC2034
TARGET=x86-64
sdk_matrix_resolve() {
	SDK_MATRIX_TARGET=$1
	SDK_MATRIX_VERSION=$2
	SDK_MATRIX_VERSION_LABEL=24.10.8
	case "$1" in
		armsr-armv8) SDK_MATRIX_PACKAGE_ARCH=aarch64_generic ;;
		*) SDK_MATRIX_PACKAGE_ARCH=x86_64 ;;
	esac
}
sdk_matrix_source_date_epoch() { printf '1700000000'; }
sdk_matrix_feeds_ready() { [[ "${VERIFY_FEEDS_READY:-1}" == 1 ]]; }
VERIFY_FAIL=
VERIFY_MAKE_COUNT=0
VERIFY_COPY_COUNT=0
sdk_matrix_make() {
	VERIFY_MAKE_COUNT=$((VERIFY_MAKE_COUNT + 1))
	case "$VERIFY_FAIL:$VERIFY_MAKE_COUNT" in make1:1|make2:2) return 42 ;; esac
	return 0
}
sdk_matrix_clean_package() { [[ "$VERIFY_FAIL" != clean ]]; }
sdk_matrix_copy_out() {
	VERIFY_COPY_COUNT=$((VERIFY_COPY_COUNT + 1))
	case "$VERIFY_FAIL:$VERIFY_COPY_COUNT" in copy1:1|copy2:2) return 43 ;; esac
	return 0
}

if verify_one 24.10 >/dev/null 2>&1; then
	ok "repro verifier succeeds when both build passes succeed"
else
	bad "repro verifier rejected successful build passes"
fi
run_verify_failure() {
	VERIFY_FAIL=$1
	VERIFY_MAKE_COUNT=0
	VERIFY_COPY_COUNT=0
	if verify_one 24.10 >/dev/null 2>&1; then
		bad "repro verifier accepted injected $1 failure"
	else
		ok "repro verifier propagates injected $1 failure"
	fi
}
run_verify_failure make1
run_verify_failure copy1
run_verify_failure clean
run_verify_failure make2
run_verify_failure copy2

cat > "$VERIFY_ROOT/scripts/docker-sdk.sh" <<'FAILSDK'
#!/bin/sh
exit 41
FAILSDK
chmod +x "$VERIFY_ROOT/scripts/docker-sdk.sh"
VERIFY_FEEDS_READY=0 VERIFY_FAIL=setup
if verify_one 24.10 >/dev/null 2>&1; then
	bad "repro verifier accepted failed initial SDK build"
else
	ok "repro verifier propagates failed initial SDK build"
fi

[ "$fail" -eq 0 ] || exit 1
echo "reproducible-build contract tests passed"
