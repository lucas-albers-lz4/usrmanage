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
	sed -n '1,10p' "${BASH_SOURCE[0]}"
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--version) VERSIONS=("${2:?}"); shift 2 ;;
			--target) TARGET="${2:?}"; shift 2 ;;
			-h | --help) usage; exit 0 ;;
			*) echo "unknown arg: $1" >&2; usage >&2; return 1 ;;
		esac
	done
}

artifact_shas() {
	# Validate and hash both mandatory packages from the selected build arch.
	local version_label="$1"
	local dir="${ROOT}/out/${SDK_MATRIX_PACKAGE_ARCH}/${version_label}/usrmanage"
	local f digest_line
	local -a files=() hashes=()
	sdk_matrix_validate_package_dir "$dir" "$SDK_MATRIX_VERSION" || return 1
	shopt -s nullglob
	case "$SDK_MATRIX_VERSION" in
		24.10 | 24.10.8)
			files=("${dir}"/usrmanage_*_all.ipk "${dir}"/luci-app-usrmanage_*_all.ipk)
			;;
		25.12 | 25.12.5)
			files=("${dir}"/usrmanage-*.apk "${dir}"/usrmanage_*.apk \
				"${dir}"/luci-app-usrmanage-*.apk "${dir}"/luci-app-usrmanage_*.apk)
			;;
	esac
	shopt -u nullglob
	[[ ${#files[@]} -eq 2 ]] || return 1
	for f in "${files[@]}"; do
		digest_line=$(sha256sum "$f") || return 1
		hashes+=("$digest_line")
	done
	printf '%s\n' "${hashes[@]}" | sort -k2
}

verify_one() {
	local version_key="$1" label map1 map2
	sdk_matrix_validate_version "$version_key" || return 1
	sdk_matrix_validate_target "$TARGET" || return 1
	sdk_matrix_resolve "$TARGET" "$version_key" || return 1
	label="$SDK_MATRIX_VERSION_LABEL"

	export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(sdk_matrix_source_date_epoch)}"
	echo "== reproducible build: ${version_key} (${label}) SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} ==" >&2

	if ! sdk_matrix_feeds_ready 2>/dev/null; then
		echo "→ initial build (feeds setup)..." >&2
		"${ROOT}/scripts/docker-sdk.sh" build --target "$TARGET" --version "$version_key" || {
			echo "initial build failed for ${version_key}" >&2
			return 1
		}
	else
		echo "→ build pass 1..." >&2
		sdk_matrix_make || { echo "build pass 1 failed for ${version_key}" >&2; return 1; }
		sdk_matrix_copy_out || { echo "copy-out pass 1 failed for ${version_key}" >&2; return 1; }
	fi

	map1="$(artifact_shas "$label")" || {
		echo "no artifacts after pass 1 for ${label}" >&2
		return 1
	}
	echo "  pass 1:" >&2
	while IFS= read -r _line || [[ -n "${_line:-}" ]]; do
		printf '    %s\n' "$_line"
	done <<< "$map1" >&2

	echo "→ clean + build pass 2..." >&2
	sdk_matrix_clean_package || { echo "clean failed for ${version_key}" >&2; return 1; }
	sdk_matrix_make || { echo "build pass 2 failed for ${version_key}" >&2; return 1; }
	sdk_matrix_copy_out || { echo "copy-out pass 2 failed for ${version_key}" >&2; return 1; }

	map2="$(artifact_shas "$label")" || {
		echo "no artifacts after pass 2 for ${label}" >&2
		return 1
	}
	echo "  pass 2:" >&2
	while IFS= read -r _line || [[ -n "${_line:-}" ]]; do
		printf '    %s\n' "$_line"
	done <<< "$map2" >&2

	if [[ "$map1" != "$map2" ]]; then
		echo "REPRODUCIBILITY FAIL: ${version_key} sha256 mismatch" >&2
		diff -u <(echo "$map1") <(echo "$map2") >&2 || true
		return 1
	fi
	echo "== OK: ${version_key} reproducible ==" >&2
}

main() {
	local v fail=0
	parse_args "$@" || return 1
	for v in "${VERSIONS[@]}"; do
		verify_one "$v" || fail=1
	done
	[[ $fail -eq 0 ]] || return 1
	echo "All requested versions are reproducible." >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
