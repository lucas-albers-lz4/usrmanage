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
need "$FEED/usrmanage/files/usr/lib/usrmanage/usrmanage-luci-login.sh"
need "$FEED/usrmanage/files/usr/lib/usrmanage/usrmanage-health.sh"
need "$FEED/usrmanage/files/etc/sudoers.d/usrmanage"
need "$FEED/usrmanage/files/etc/usrmanage/users"
need "$FEED/usrmanage/files/etc/uci-defaults/90-usrmanage"
need "$FEED/usrmanage/files/etc/uci-defaults/91-usrmanage-diagnostic-rpc"

need "$FEED/luci-app-usrmanage/Makefile"
need "$FEED/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js"
need "$FEED/luci-app-usrmanage/root/usr/libexec/rpcd/usrmanage"
need "$FEED/luci-app-usrmanage/root/usr/share/luci/menu.d/luci-app-usrmanage.json"
need "$FEED/luci-app-usrmanage/root/usr/share/luci/menu.d/z-luci-app-usrmanage-logout.json"
need "$FEED/luci-app-usrmanage/root/usr/share/rpcd/acl.d/luci-app-usrmanage.json"
need "$FEED/luci-app-usrmanage/root/etc/uci-defaults/91-usrmanage-readonly-observer"
need "$FEED/luci-app-usrmanage/root/etc/uci-defaults/92-usrmanage-diagnostic-rpc"

grep -q 'PKGARCH:=all' "$FEED/usrmanage/Makefile"
grep -q 'LUCI_PKGARCH:=all' "$FEED/luci-app-usrmanage/Makefile"
grep -q 'Apache-2.0' "$FEED/usrmanage/Makefile"
grep -q '+usrmanage' "$FEED/luci-app-usrmanage/Makefile"
# Version pins must not appear in LUCI_DEPENDS (OpenWrt parses "(>=…)" as a package name).
if grep -qE 'LUCI_DEPENDS:.*\(>=' "$FEED/luci-app-usrmanage/Makefile"; then
	echo "LUCI_DEPENDS must not contain version constraints; use LUCI_EXTRA_DEPENDS" >&2
	exit 1
fi
grep -q '%wheel' "$FEED/usrmanage/files/etc/sudoers.d/usrmanage"
# V3: install path must chmod 0440 (git does not preserve mode bits on the
# feed-tree source file; doctor asserts the live fragment on-device).
grep -qE 'chmod 0440.*sudoers\.d/usrmanage' "$FEED/usrmanage/Makefile" \
	|| { echo "Makefile missing chmod 0440 for sudoers install" >&2; exit 1; }
grep -q 'chmod 0440 /etc/sudoers.d/usrmanage' \
	"$FEED/usrmanage/files/etc/uci-defaults/90-usrmanage" \
	|| { echo "uci-defaults missing chmod 0440 for sudoers" >&2; exit 1; }

# JSON ACLs parse
python3 -c "import json; json.load(open('$FEED/luci-app-usrmanage/root/usr/share/rpcd/acl.d/luci-app-usrmanage.json'))"
python3 -c "import json; json.load(open('$FEED/luci-app-usrmanage/root/usr/share/luci/menu.d/luci-app-usrmanage.json'))"
python3 -c "import json; json.load(open('$FEED/luci-app-usrmanage/root/usr/share/luci/menu.d/z-luci-app-usrmanage-logout.json'))"

# Logout menu: readonly session ACL may end LuCI without luci-base (issue #142).
# LuCI depends.acl is AND — list only luci-app-usrmanage-session (not luci-base).
python3 - "$FEED/luci-app-usrmanage/root/usr/share/luci/menu.d/z-luci-app-usrmanage-logout.json" <<'PY'
import json, sys
menu = json.load(open(sys.argv[1]))
logout = menu["admin/logout"]["depends"]["acl"]
if logout != ["luci-app-usrmanage-session"]:
	raise SystemExit(f"menu logout depends: {logout!r}")
print("menu logout depends: ok")
PY

# Health ACL: read usrmanage.health only; no write object; no globs. Session: no uci.
python3 - "$FEED/luci-app-usrmanage/root/usr/share/rpcd/acl.d/luci-app-usrmanage.json" <<'PY'
import json, sys
acl = json.load(open(sys.argv[1]))
h = acl["luci-app-usrmanage-health"]
assert "write" not in h, "health ACL must not have write"
assert h["read"]["ubus"]["usrmanage"] == ["health"], h["read"]
blob = json.dumps(h)
assert "*" not in blob and "?" not in blob, "globs in health ACL"
sess = acl["luci-app-usrmanage-session"]["read"]
assert "uci" not in sess and "uci" not in sess.get("ubus", {}), sess
assert "luci-app-usrmanage" in acl
print("acl health/session: ok")

diag = acl.get("luci-app-usrmanage-diagnostic-rpc")
assert diag is not None, "missing luci-app-usrmanage-diagnostic-rpc"
assert "write" not in diag, "diagnostic-rpc ACL must not have write"
assert "file" not in (diag.get("read") or {}), "diagnostic-rpc must not grant file"
ub = diag["read"]["ubus"]
# Exact allowlist — extra methods (esp. getWirelessDevices) must fail CI.
assert set(ub) == {"network.interface", "network", "uci", "luci-rpc"}, ub
assert set(ub["network.interface"]) == {"dump"}, ub
assert set(ub["network"]) == {"get_proto_handlers"}, ub
assert set(ub["uci"]) == {"get", "changes"}, ub
assert set(ub["luci-rpc"]) == {"getBoardJSON", "getHostHints", "getNetworkDevices"}, ub
print("acl diagnostic-rpc: ok")

PY

# LuCI APP_VERSION must match luci-app Makefile PKG_VERSION (fwlive-style)
pkg_ver=$(sed -n 's/^PKG_VERSION:=//p' "$FEED/luci-app-usrmanage/Makefile" | head -1)
grep -q "LUCI_EXTRA_DEPENDS:=usrmanage (>=$pkg_ver)" "$FEED/luci-app-usrmanage/Makefile" \
	|| { echo "LUCI_EXTRA_DEPENDS must pin usrmanage (>=$pkg_ver)" >&2; exit 1; }
view_js="$FEED/luci-app-usrmanage/htdocs/luci-static/resources/view/system/usrmanage.js"
grep -q "APP_VERSION = '$pkg_ver'" "$view_js" \
	|| { echo "APP_VERSION mismatch in usrmanage.js (want $pkg_ver)" >&2; exit 1; }

echo "package layout: ok (arch-independent all)"
echo "matrix: 24.10/25.12 × x86-64 + armsr-armv8; feed stages x86_64 _all artifacts"
