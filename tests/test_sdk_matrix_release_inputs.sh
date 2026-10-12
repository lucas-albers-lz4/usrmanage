#!/usr/bin/env bash
# Focused host contracts for SDK version validation and fresh copy-out (#185/#194).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/sdk-matrix.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for version in 24.10 24.10.8 25.12 25.12.5; do
	sdk_matrix_validate_version "$version" || bad "supported version rejected: $version"
done
for version in 23.05 snapshot nonsense 25.12.99 24.10.7; do
	if sdk_matrix_validate_version "$version" >/dev/null 2>&1; then
		bad "unsupported version accepted: $version"
	else
		ok "unsupported version rejected: $version"
	fi
done

make_ipk_fixture() {
	local name=$1 version=$2 arch=$3 output=$4 stage
	stage="$TMP/ipk-$name"
	rm -rf "$stage"
	mkdir -p "$stage/control"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$name" "$version" "$arch" >"$stage/control/control"
	printf '2.0\n' >"$stage/debian-binary"
	tar -czf "$stage/control.tar.gz" -C "$stage/control" .
	tar -czf "$output" -C "$stage" debian-binary control.tar.gz
}

make_apk_fixture() {
	local name=$1 version=$2 arch=$3 output=$4
	printf 'ADB fixture\n' >"$output"
	printf '{"info":{"name":"%s","version":"%s","arch":"%s"}}\n' \
		"$name" "$version" "$arch" >"${output}.metadata.json"
}

# Replace only the SDK metadata reader boundary; no Docker daemon is needed.
# shellcheck disable=SC2329
sdk_matrix_read_apk_metadata() {
	cat "${1}.metadata.json"
}

expected_usr=$(sdk_matrix_expected_package_version usrmanage)
expected_luci=$(sdk_matrix_expected_package_version luci-app-usrmanage)
ipk_dir="$TMP/ipk-output"
mkdir -p "$ipk_dir"
make_ipk_fixture usrmanage "$expected_usr" all "$ipk_dir/usrmanage_${expected_usr}_all.ipk"
make_ipk_fixture luci-app-usrmanage "$expected_luci" all "$ipk_dir/luci-app-usrmanage_${expected_luci}_all.ipk"
sdk_matrix_validate_package_dir "$ipk_dir" 24.10 \
	&& ok "24.10 artifact set validates both opkg packages" \
	|| bad "24.10 artifact set validation failed"
make_ipk_fixture usrmanage 0.1.1-r1 all "$ipk_dir/usrmanage_0.1.1-r1_all.ipk"
if sdk_matrix_validate_package_dir "$ipk_dir" 24.10 >/dev/null 2>&1; then
	bad "stale duplicate package version accepted"
else
	ok "stale package duplicate rejected"
fi
rm -f "$ipk_dir/usrmanage_0.1.1-r1_all.ipk" "$ipk_dir/luci-app-usrmanage_"*.ipk
if sdk_matrix_validate_package_dir "$ipk_dir" 24.10 >/dev/null 2>&1; then
	bad "missing mandatory LuCI package accepted"
else
	ok "missing mandatory package rejected"
fi

apk_dir="$TMP/apk-output"
mkdir -p "$apk_dir"
make_apk_fixture usrmanage "$expected_usr" noarch "$apk_dir/usrmanage-${expected_usr}.apk"
make_apk_fixture luci-app-usrmanage "$expected_luci" noarch "$apk_dir/luci-app-usrmanage-${expected_luci}.apk"
sdk_matrix_validate_package_dir "$apk_dir" 25.12 \
	&& ok "25.12 artifact set validates both APK packages" \
	|| bad "25.12 artifact set validation failed"
make_apk_fixture usrmanage "$expected_usr" x86_64 "$apk_dir/usrmanage-${expected_usr}.apk"
if sdk_matrix_validate_package_dir "$apk_dir" 25.12 >/dev/null 2>&1; then
	bad "architecture-mismatched APK accepted"
else
	ok "architecture-mismatched APK rejected"
fi

# Exercise copy-out in a disposable root and fake only the Docker boundary.
copy_root="$TMP/copy-root"
mkdir -p "$copy_root/scripts/lib" "$copy_root/openwrt-feed/usrmanage" \
	"$copy_root/openwrt-feed/luci-app-usrmanage" "$copy_root/out/x86_64/24.10.8/usrmanage"
cp "$ROOT/scripts/lib/sdk-matrix.sh" "$copy_root/scripts/lib/sdk-matrix.sh"
cp "$ROOT/openwrt-feed/usrmanage/Makefile" "$copy_root/openwrt-feed/usrmanage/Makefile"
cp "$ROOT/openwrt-feed/luci-app-usrmanage/Makefile" "$copy_root/openwrt-feed/luci-app-usrmanage/Makefile"

# shellcheck disable=SC2329
docker() {
	[ "${COPY_OUT_FAIL:-0}" = 0 ] || return 42
	local dest="${COPY_OUT_ROOT}/x86_64/24.10.8/usrmanage"
	mkdir -p "$dest"
	cp "$COPY_OUT_PACKAGES/usrmanage_${COPY_OUT_VERSION}_all.ipk" "$dest/"
	cp "$COPY_OUT_PACKAGES/luci-app-usrmanage_${COPY_OUT_VERSION}_all.ipk" "$dest/"
}

mkdir -p "$TMP/copy-packages"
make_ipk_fixture usrmanage "$expected_usr" all "$TMP/copy-packages/usrmanage_${expected_usr}_all.ipk"
make_ipk_fixture luci-app-usrmanage "$expected_luci" all "$TMP/copy-packages/luci-app-usrmanage_${expected_luci}_all.ipk"
mkdir -p "$copy_root/out/x86_64/24.10.8/usrmanage"
touch "$copy_root/out/x86_64/24.10.8/usrmanage/stale.ipk"
COPY_OUT_ROOT="$copy_root/out" COPY_OUT_PACKAGES="$TMP/copy-packages" COPY_OUT_VERSION="$expected_usr"
export COPY_OUT_ROOT COPY_OUT_PACKAGES COPY_OUT_VERSION
(
	# shellcheck disable=SC1091
	source "$copy_root/scripts/lib/sdk-matrix.sh"
	sdk_matrix_resolve x86-64 24.10
	sdk_matrix_copy_out
)
[ ! -e "$copy_root/out/x86_64/24.10.8/usrmanage/stale.ipk" ] \
	&& [ -f "$copy_root/out/x86_64/24.10.8/usrmanage/usrmanage_${expected_usr}_all.ipk" ] \
	&& [ -f "$copy_root/out/x86_64/24.10.8/usrmanage/luci-app-usrmanage_${expected_luci}_all.ipk" ] \
	&& ok "SDK copy-out prunes stale files and exports both packages" \
	|| bad "SDK copy-out did not produce a fresh complete package set"

COPY_OUT_FAIL=1
export COPY_OUT_FAIL
if (
	# shellcheck disable=SC1091
	source "$copy_root/scripts/lib/sdk-matrix.sh"
	sdk_matrix_resolve x86-64 24.10
	sdk_matrix_copy_out
) >/dev/null 2>&1; then
	bad "SDK copy-out accepted failed export"
else
	[ ! -e "$copy_root/out/x86_64/24.10.8/usrmanage/usrmanage_${expected_usr}_all.ipk" ] \
		&& ok "failed export leaves no stale artifact" \
		|| bad "failed export left an artifact"
fi

[ "$fail" -eq 0 ] || exit 1
echo "SDK release-input tests passed"
