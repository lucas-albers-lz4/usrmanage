#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Validate feed package layout for arch-independent 24.10/25.12 builds.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FEED="$ROOT/openwrt-feed"

need() {
	[ -e "$1" ] || { echo "missing: $1" >&2; exit 1; }
}

need "$FEED/usrmanage/Makefile"
need "$FEED/usrmanage/files/usr/sbin/usrmanage"
need "$FEED/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"
need "$FEED/usrmanage/files/etc/sudoers.d/usrmanage"
need "$FEED/usrmanage/files/etc/usrmanage/users"
need "$FEED/usrmanage/files/etc/uci-defaults/90-usrmanage"

need "$FEED/luci-app-usrmanage/Makefile"
need "$FEED/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js"
need "$FEED/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage"
need "$FEED/luci-app-usrmanage/root/usr/share/luci/menu.d/luci-app-usrmanage.json"
need "$FEED/luci-app-usrmanage/root/usr/share/rpcd/acl.d/luci-app-usrmanage.json"

grep -q 'PKGARCH:=all' "$FEED/usrmanage/Makefile"
grep -q 'LUCI_PKGARCH:=all' "$FEED/luci-app-usrmanage/Makefile"
grep -q 'Apache-2.0' "$FEED/usrmanage/Makefile"
grep -q '+usrmanage' "$FEED/luci-app-usrmanage/Makefile"
grep -q '%wheel' "$FEED/usrmanage/files/etc/sudoers.d/usrmanage"

# JSON ACLs parse
python3 -c "import json; json.load(open('$FEED/luci-app-usrmanage/root/usr/share/rpcd/acl.d/luci-app-usrmanage.json'))"
python3 -c "import json; json.load(open('$FEED/luci-app-usrmanage/root/usr/share/luci/menu.d/luci-app-usrmanage.json'))"

# LuCI APP_VERSION must match luci-app Makefile PKG_VERSION (fwlive-style)
pkg_ver=$(sed -n 's/^PKG_VERSION:=//p' "$FEED/luci-app-usrmanage/Makefile" | head -1)
view_js="$FEED/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js"
grep -q "APP_VERSION = '$pkg_ver'" "$view_js" \
	|| { echo "APP_VERSION mismatch in usrmanage.js (want $pkg_ver)" >&2; exit 1; }

echo "package layout: ok (arch-independent all)"
echo "matrix: 24.10/25.12 × x86-64 + armsr-armv8; feed stages x86_64 _all artifacts"
