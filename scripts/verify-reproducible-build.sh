#!/usr/bin/env bash
# Verify bit-identical usrmanage + luci-app-usrmanage builds (reproducibility gate).
#
#   ./scripts/verify-reproducible-build.sh
#   ./scripts/verify-reproducible-build.sh --version 24.10
#   SOURCE_DATE_EPOCH=1700000000 ./scripts/verify-reproducible-build.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sdk-matrix.sh
source "${ROOT}/scripts/lib/sdk-matrix.sh"

TARGET="${OWRT_VERIFY_TARGET:-x86-64}"
VERSIONS=(24.10 25.12)

usage() {
	sed -n '1,10p' "$0"
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSIONS=("${2:?}"); shift 2 ;;
		--target) TARGET="${2:?}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

artifact_shas() {
	# Print "sha256 path" lines for all packages in a version out dir
	local version_label="$1"
	local dir="${ROOT}/out/x86_64/${version_label}/usrmanage"
	local f
	shopt -s nullglob
	local files=(
		"${dir}"/usrmanage_*_all.ipk
		"${dir}"/luci-app-usrmanage_*_all.ipk
		"${dir}"/usrmanage-*.apk
		"${dir}"/luci-app-usrmanage-*.apk
	)
	shopt -u nullglob
	[[ ${#files[@]} -ge 1 ]] || return 1
	for f in "${files[@]}"; do
		sha256sum "$f"
	done | sort -k2
}

verify_one() {
	local version_key="$1" label map1 map2
	sdk_matrix_validate_version "$version_key"
	sdk_matrix_validate_target "$TARGET"
	sdk_matrix_resolve "$TARGET" "$version_key"
	label="$SDK_MATRIX_VERSION_LABEL"

	export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(sdk_matrix_source_date_epoch)}"
	echo "== reproducible build: ${version_key} (${label}) SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ==" >&2

	if ! sdk_matrix_feeds_ready 2>/dev/null; then
		echo "→ initial build (feeds setup)..." >&2
		"${ROOT}/scripts/docker-sdk.sh" build --target "$TARGET" --version "$version_key"
	else
		echo "→ build pass 1..." >&2
		sdk_matrix_make
		sdk_matrix_copy_out
	fi

	map1="$(artifact_shas "$label")" || {
		echo "no artifacts after pass 1 for ${label}" >&2
		return 1
	}
	echo "  pass 1:" >&2
	echo "$map1" | sed 's/^/    /' >&2

	echo "→ clean + build pass 2..." >&2
	sdk_matrix_clean_package
	sdk_matrix_make
	sdk_matrix_copy_out

	map2="$(artifact_shas "$label")" || {
		echo "no artifacts after pass 2 for ${label}" >&2
		return 1
	}
	echo "  pass 2:" >&2
	echo "$map2" | sed 's/^/    /' >&2

	if [[ "$map1" != "$map2" ]]; then
		echo "REPRODUCIBILITY FAIL: ${version_key} sha256 mismatch" >&2
		diff -u <(echo "$map1") <(echo "$map2") >&2 || true
		return 1
	fi
	echo "== OK: ${version_key} reproducible ==" >&2
}

main() {
	local v fail=0
	for v in "${VERSIONS[@]}"; do
		verify_one "$v" || fail=1
	done
	[[ $fail -eq 0 ]] || exit 1
	echo "All requested versions are reproducible." >&2
}

main
