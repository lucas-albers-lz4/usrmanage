#!/usr/bin/env bash
# Unified OpenWrt SDK driver for usrmanage multi-version / multi-target builds.
#
#   ./scripts/docker-sdk.sh list
#   ./scripts/docker-sdk.sh build --target x86-64 --version 24.10
#   ./scripts/docker-sdk.sh build-all
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"

usage() {
	cat <<'EOF'
Usage: docker-sdk.sh <command> [options] [make-args...]

Commands:
  list       Show supported target × version combinations
  setup      Configure feeds + defconfig (once per SDK volume)
  make       Compile usrmanage + luci-app-usrmanage
  copy-out   Copy packages to out/<arch>/<version>/
  build      setup (if needed) + make + copy-out
  build-all  Run build for every matrix cell (or filter with --target/--version)

Options:
  --target TARGET    armsr-armv8 | x86-64   (default: x86-64)
  --version VERSION  25.12 | 24.10 | 23.05   (default: 24.10)

Parallelism: OWRT_MAKE_JOBS=16 or make -j N
EOF
}

CMD="${1:-}"
shift || true

TARGET="${OWRT_SDK_TARGET:-x86-64}"
VERSION="${OWRT_SDK_VERSION:-24.10}"
MAKE_ARGS=()
FILTER_TARGET=0
FILTER_VERSION=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--target)
			TARGET="${2:?}"
			FILTER_TARGET=1
			shift 2
			;;
		--version)
			VERSION="${2:?}"
			FILTER_VERSION=1
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			MAKE_ARGS+=("$1")
			shift
			;;
	esac
done

run_one() {
	local t="$1" v="$2"
	sdk_matrix_validate_target "$t"
	sdk_matrix_validate_version "$v"
	sdk_matrix_resolve "$t" "$v"
	echo "→ ${SDK_MATRIX_IMAGE} (volume: ${SDK_MATRIX_VOLUME})" >&2
}

case "$CMD" in
	list)
		sdk_matrix_list
		;;
	setup)
		run_one "$TARGET" "$VERSION"
		sdk_matrix_feeds_setup
		echo "Feeds ready. Build: ./scripts/docker-sdk.sh make --target $TARGET --version $VERSION" >&2
		;;
	make)
		run_one "$TARGET" "$VERSION"
		sdk_matrix_make "${MAKE_ARGS[@]}"
		echo "Copy: ./scripts/docker-sdk.sh copy-out --target $TARGET --version $VERSION" >&2
		;;
	copy-out)
		run_one "$TARGET" "$VERSION"
		sdk_matrix_copy_out
		;;
	build)
		run_one "$TARGET" "$VERSION"
		if ! sdk_matrix_feeds_ready; then
			sdk_matrix_feeds_setup
		fi
		sdk_matrix_make "${MAKE_ARGS[@]}"
		sdk_matrix_copy_out
		;;
	build-all)
		targets=("${SDK_MATRIX_TARGETS[@]}")
		versions=("${SDK_MATRIX_VERSIONS[@]}")
		if [[ "$FILTER_TARGET" -eq 1 ]]; then
			targets=("$TARGET")
		fi
		if [[ "$FILTER_VERSION" -eq 1 ]]; then
			versions=("$VERSION")
		fi
		for t in "${targets[@]}"; do
			for v in "${versions[@]}"; do
				run_one "$t" "$v"
				if ! sdk_matrix_feeds_ready; then
					sdk_matrix_feeds_setup
				fi
				sdk_matrix_make "${MAKE_ARGS[@]}"
				sdk_matrix_copy_out
				echo >&2
			done
		done
		echo "All requested matrix builds finished under ${ROOT}/out/" >&2
		;;
	'' | -h | --help | help)
		usage
		exit 0
		;;
	*)
		echo "unknown command: $CMD" >&2
		usage >&2
		exit 1
		;;
esac
