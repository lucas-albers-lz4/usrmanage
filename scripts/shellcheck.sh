#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# ShellCheck ash-safe scripts
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

# Discover any NEW shipped ash script under the feed so it cannot silently
# escape this gate (the explicit list below still covers every extensionless
# entrypoint, e.g. usr/sbin/usrmanage, uci-defaults/90-usrmanage, rpcd).
find "$ROOT/openwrt-feed" -type f -name '*.sh' -print0 | xargs -0 -r shellcheck -s sh

shellcheck -s sh \
	"$ROOT/openwrt-feed/usrmanage/files/usr/sbin/usrmanage" \
	"$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh" \
	"$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-luci-login.sh" \
	"$ROOT/openwrt-feed/usrmanage/files/etc/uci-defaults/90-usrmanage" \
	"$ROOT/openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage" \
	"$ROOT/scripts/smoke-package-layout.sh" \
	"$ROOT/scripts/smoke-host.sh"

# Bash SDK/publish helpers (blocking — no || true; P1 / #117)
# SC1091: sourced helpers use runtime paths shellcheck cannot follow without -x graph.
shellcheck -s bash -e SC1091 \
	"$ROOT/scripts/docker-sdk.sh" \
	"$ROOT/scripts/lib/sdk-matrix.sh" \
	"$ROOT/scripts/publish-packages.sh" \
	"$ROOT/scripts/verify-reproducible-build.sh" \
	"$ROOT/scripts/lib/feed-publish.sh" \
	"$ROOT/scripts/lib/feed-keys.sh" \
	"$ROOT/scripts/validate-feed-keys.sh" \
	"$ROOT/scripts/wait-feed-pages.sh" \
	"$ROOT/scripts/download-openwrt-x86-64.sh" \
	"$ROOT/tests/test_sdk_matrix_digests.sh"

echo "shellcheck: ok"
