#!/usr/bin/env bash
# Install usrmanage + luci-app-usrmanage on a QEMU guest from the GitHub Pages feed.
#
#   USRMANAGE_FEED_BASE_URL=https://lucas-albers-lz4.github.io/usrmanage-packages \
#     ./scripts/qemu-install-from-feed.sh --version 24.10
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/sdk-matrix.sh
source "${ROOT}/scripts/lib/sdk-matrix.sh"

OPENWRT_HOST="${OPENWRT_HOST:-127.0.0.1}"
OPENWRT_SSH_PORT="${OPENWRT_SSH_PORT:-2222}"
OPENWRT_USER="${OPENWRT_USER:-root}"
USRMANAGE_FEED_BASE_URL="${USRMANAGE_FEED_BASE_URL:-https://lucas-albers-lz4.github.io/usrmanage-packages}"
VERSION="${OWRT_USRMANAGE_VERSION:-24.10}"
RUN_SMOKE=1

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

usage() {
	cat <<EOF
Usage: qemu-install-from-feed.sh [options]

Options:
  --version VERSION   24.10 | 25.12 (default: 24.10)
  --no-smoke          skip qemu-smoke-usrmanage.sh after install
  -h, --help

Environment:
  USRMANAGE_FEED_BASE_URL   GitHub Pages base (no trailing slash)
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) VERSION="${2:?}"; shift 2 ;;
		--no-smoke) RUN_SMOKE=0; shift ;;
		-h | --help) usage; exit 0 ;;
		*) echo "unknown arg: $1" >&2; usage >&2; exit 1 ;;
	esac
done

sdk_matrix_validate_version "$VERSION"
base="${USRMANAGE_FEED_BASE_URL%/}"
opkg_key_url="${OPKG_FEED_PUBLIC_KEY_URL:-${base}/public.key}"
apk_key_url="${APK_FEED_PUBLIC_KEY_URL:-${base}/usrmanage-feed.rsa.pub}"

# Map release line → feed directory (same as publish layout).
feed_dir="$VERSION"
[[ "$VERSION" == "25.12" ]] && feed_dir="25.12"

ssh_run() {
	ssh -p "$OPENWRT_SSH_PORT" "${SSH_OPTS[@]}" "${OPENWRT_USER}@${OPENWRT_HOST}" "$@"
}

guest_uses_apk() {
	ssh_run 'command -v apk >/dev/null 2>&1'
}

install_opkg() {
	local feed_url="${base}/${feed_dir}"
	echo "→ opkg feed ${feed_url}" >&2
	ssh_run "wget -O /tmp/usrmanage-feed.key '${opkg_key_url}'"
	ssh_run 'opkg-key add /tmp/usrmanage-feed.key'
	ssh_run "grep -q 'src/gz usrmanage ${feed_url}' /etc/opkg/customfeeds.conf 2>/dev/null || \
		echo 'src/gz usrmanage ${feed_url}' >> /etc/opkg/customfeeds.conf"
	ssh_run 'opkg update'
	ssh_run 'opkg install usrmanage luci-app-usrmanage'
}

install_apk() {
	local index_url="${base}/${feed_dir}/all/packages.adb"
	echo "→ apk index ${index_url}" >&2
	ssh_run "wget -O /tmp/usrmanage-feed.rsa.pub '${apk_key_url}'"
	ssh_run 'mkdir -p /etc/apk/keys /etc/apk/repositories.d'
	ssh_run 'cp /tmp/usrmanage-feed.rsa.pub /etc/apk/keys/usrmanage-feed.rsa.pub'
	ssh_run "grep -qF '${index_url}' /etc/apk/repositories.d/usrmanage.list 2>/dev/null || \
		echo '${index_url}' >> /etc/apk/repositories.d/usrmanage.list"
	ssh_run 'apk update'
	ssh_run 'apk add usrmanage luci-app-usrmanage'
}

echo "Installing usrmanage from ${base} (OpenWrt ${VERSION})..." >&2

if guest_uses_apk; then
	install_apk
else
	install_opkg
fi

# Ensure rpcd picks up the new plugin / ACL.
ssh_run '/etc/init.d/rpcd restart 2>/dev/null || true'
ssh_run '/etc/init.d/uhttpd restart 2>/dev/null || true'

if [[ "$RUN_SMOKE" -eq 1 ]]; then
	"${ROOT}/scripts/qemu-smoke-usrmanage.sh"
fi

echo "Feed install complete." >&2
