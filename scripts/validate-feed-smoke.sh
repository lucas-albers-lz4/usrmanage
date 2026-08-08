#!/usr/bin/env bash
# End-to-end: boot QEMU x86 guest, install from live feed, smoke test, stop.
#
#   ./scripts/validate-feed-smoke.sh --version 24.10
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${OWRT_VALIDATE_VERSION:-24.10}"
FEED_URL="${USRMANAGE_FEED_BASE_URL:-https://lucas-albers-lz4.github.io/usrmanage-packages}"
IMG_RELEASE=""

usage() {
	cat <<EOF
Usage: validate-feed-smoke.sh [options]

Options:
  --version VERSION   24.10 | 25.12 (default: 24.10)
  --feed-url URL      override USRMANAGE_FEED_BASE_URL
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--feed-url) FEED_URL="${2:?}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

case "$VERSION" in
	24.10) IMG_RELEASE="24.10.5" ;;
	25.12) IMG_RELEASE="25.12.0" ;;
	*) echo "unsupported version: $VERSION" >&2; exit 1 ;;
esac

IMG="${ROOT}/lab/images/openwrt-x86-64-${IMG_RELEASE}.img"
[[ -f "$IMG" ]] || {
	echo "missing ${IMG}" >&2
	echo "Copy a prepared OpenWrt combined ext4 image into lab/images/ first." >&2
	exit 1
}

echo "== feed smoke: ${VERSION} feed=${FEED_URL} ==" >&2

# Prepare if network.lan is still static (idempotent-ish).
if ! sudo -n true 2>/dev/null; then
	echo "note: may prompt for sudo to prepare image" >&2
fi
sudo OWRT_IMG="$IMG" "${ROOT}/scripts/qemu-lab-prepare-image.sh"

export OWRT_RELEASE="$IMG_RELEASE"
export OWRT_X86_IMG="$IMG"
export OWRT_QEMU_DAEMON=1
export USRMANAGE_FEED_BASE_URL="$FEED_URL"

"${ROOT}/scripts/run-openwrt-x86-qemu.sh" --stop >/dev/null 2>&1 || true
OWRT_RELEASE="$IMG_RELEASE" OWRT_X86_IMG="$IMG" OWRT_QEMU_DAEMON=1 \
	"${ROOT}/scripts/run-openwrt-x86-qemu.sh"

cleanup() {
	"${ROOT}/scripts/run-openwrt-x86-qemu.sh" --stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${ROOT}/scripts/qemu-wait-guest.sh"
export USRMANAGE_FEED_BASE_URL="$FEED_URL"
"${ROOT}/scripts/qemu-install-from-feed.sh" --version "$VERSION"

echo "== feed smoke passed: ${VERSION} ==" >&2
