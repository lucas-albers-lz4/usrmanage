#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# ShellCheck ash-safe scripts
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

shellcheck -s sh \
	"$ROOT/openwrt-feed/usrmanage/files/usr/sbin/usrmanage" \
	"$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh" \
	"$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-luci-login.sh" \
	"$ROOT/openwrt-feed/usrmanage/files/etc/uci-defaults/90-usrmanage" \
	"$ROOT/openwrt-feed/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage" \
	"$ROOT/scripts/smoke-package-layout.sh" \
	"$ROOT/scripts/smoke-host.sh"

# Bash SDK/publish helpers
shellcheck -s bash \
	"$ROOT/scripts/docker-sdk.sh" \
	"$ROOT/scripts/lib/sdk-matrix.sh" \
	"$ROOT/scripts/publish-packages.sh" \
	"$ROOT/scripts/verify-reproducible-build.sh" \
	"$ROOT/scripts/lib/feed-publish.sh" \
	"$ROOT/scripts/lib/feed-keys.sh" \
	"$ROOT/scripts/validate-feed-keys.sh" \
	"$ROOT/tests/test_sdk_matrix_digests.sh" || true

echo "shellcheck: ok"
