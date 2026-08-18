#!/usr/bin/env bash
# Regression: qemu-lab-prepare-image.sh LAN network seeding / DHCP transform.
#
# Covers the v0.1.5 smoke blocker (guest never SSH-reachable because the
# stock OpenWrt image ships no /etc/config/network) plus the 25.12
# list-ipaddr existing-file path.
set -u
fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/qemu-lab-prepare-image.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The DHCP transform must (a) set lan proto=dhcp, (b) drop static
# ipaddr/netmask/list-ipaddr, (c) only touch the lan section (stop at next
# `config` block, e.g. wan). This mirrors the awk in the shipped script.
write_awk() {
	cat > "$TMP/net.awk" <<'AWK'
BEGIN { in_lan = 0 }
/^config / {
	if (in_lan) in_lan = 0
	if ($0 ~ /^config interface .lan./) in_lan = 1
}
{
	if (in_lan) {
		if ($0 ~ /option proto /) {
			print "	option proto 'dhcp'"
			next
		}
		if ($0 ~ /option ipaddr /) next
		if ($0 ~ /option netmask /) next
		if ($0 ~ /option gateway /) next
		if ($0 ~ /list ipaddr /) next
		if ($0 ~ /option ip6assign /) next
	}
	print
}
AWK
}

transform_dhcp() {
	local input="$1"
	write_awk
	printf '%b' "$input" | awk -f "$TMP/net.awk"
}

# --- Seed absent-file cases (dhcp / static) -------------------------------
seed_dhcp() {
	local mnt="$TMP/seed-dhcp"
	mkdir -p "$mnt/etc/config"
	_lan_proto='dhcp'
	cat >"$mnt/etc/config/network" <<EOF
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'auto'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto '${_lan_proto}'
EOF
	echo "	option ip6assign '60'" >>"$mnt/etc/config/network"
	cat "$mnt/etc/config/network"
	rm -rf "$mnt"
}
seed_static() {
	local mnt="$TMP/seed-static"
	mkdir -p "$mnt/etc/config"
	_lan_proto='static'
	cat >"$mnt/etc/config/network" <<EOF
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option ula_prefix 'auto'

config device
	option name 'br-lan'
	option type 'bridge'
	list ports 'eth0'

config interface 'lan'
	option device 'br-lan'
	option proto '${_lan_proto}'
EOF
	cat >>"$mnt/etc/config/network" <<EOF
	option ipaddr '172.30.77.1'
	option netmask '255.255.255.0'
EOF
	echo "	option ip6assign '60'" >>"$mnt/etc/config/network"
	cat "$mnt/etc/config/network"
	rm -rf "$mnt"
}

# 1. Seed absent file, dhcp.
out="$(seed_dhcp)"
if echo "$out" | grep -q "option proto 'dhcp'"; then
	ok "seed (absent file) dhcp sets proto=dhcp"
else
	bad "seed dhcp missing proto=dhcp"
fi

# 2. Seed absent file, static.
out="$(seed_static)"
if echo "$out" | grep -q "option proto 'static'" && echo "$out" | grep -q "option ipaddr '172.30.77.1'"; then
	ok "seed (absent file) static sets proto=static + ipaddr"
else
	bad "seed static missing static+ipaddr"
fi

# 3. Existing 25.12 list-ipaddr → dhcp, list removed, wan section preserved.
out="$(transform_dhcp $'config interface \'lan\'\n\toption device \'br-lan\'\n\toption proto \'static\'\n\tlist ipaddr \'10.10.10.1/24\'\n\toption ip6assign \'60\'\n\nconfig interface \'wan\'\n\toption proto \'dhcp\'\n')"
if echo "$out" | grep -q "option proto 'dhcp'" \
	&& ! echo "$out" | grep -q "list ipaddr" \
	&& echo "$out" | grep -q "config interface 'wan'"; then
	ok "existing 25.12 list-ipaddr → dhcp, list removed, wan kept"
else
	bad "existing 25.12 transform failed: $out"
fi

# 4. Existing classic static → dhcp, ipaddr/netmask dropped.
out="$(transform_dhcp $'config interface \'lan\'\n\toption proto \'static\'\n\toption ipaddr \'192.168.1.1\'\n\toption netmask \'255.255.255.0\'\n')"
if echo "$out" | grep -q "option proto 'dhcp'" \
	&& ! echo "$out" | grep -q "option ipaddr" \
	&& ! echo "$out" | grep -q "option netmask"; then
	ok "existing classic static → dhcp, ipaddr/netmask dropped"
else
	bad "existing classic transform failed: $out"
fi

transform_static() {
	local input="$1" lab_ip="${2:-172.30.77.1}"
	awk -v lab_ip="$lab_ip" '
		BEGIN { in_lan = 0; wrote_static = 0 }
		/^config / {
			if (in_lan && !wrote_static) {
				print "\toption ipaddr \x27" lab_ip "\x27"
				print "\toption netmask \x27255.255.255.0\x27"
				wrote_static = 1
			}
			if (in_lan) in_lan = 0
			if ($0 ~ /^config interface .lan./) in_lan = 1
		}
		{
			if (in_lan) {
				if ($0 ~ /option proto /) { print "\toption proto \x27static\x27"; next }
				if ($0 ~ /option ipaddr /) next
				if ($0 ~ /option netmask /) next
				if ($0 ~ /option gateway /) next
				if ($0 ~ /list ipaddr /) next
				if ($0 ~ /option ip6assign /) next
			}
			print
		}
		END {
			if (in_lan && !wrote_static) {
				print "\toption ipaddr \x27" lab_ip "\x27"
				print "\toption netmask \x27255.255.255.0\x27"
			}
		}
	' <<< "$input"
}

# 5. Existing DHCP config → static mode: proto=static + lab IP appended
out="$(transform_static $'config interface \'lan\'\n\toption device \'br-lan\'\n\toption proto \'dhcp\'\n')"
if echo "$out" | grep -q "option proto 'static'" \
	&& echo "$out" | grep -q "option ipaddr '172.30.77.1'" \
	&& echo "$out" | grep -q "option netmask '255.255.255.0'"; then
	ok "existing DHCP → static: proto=static + ipaddr/netmask appended"
else
	bad "existing DHCP → static failed: $out"
fi

# 6. Existing 25.12 list-ipaddr → static: list removed, lab IP written
out="$(transform_static $'config interface \'lan\'\n\toption device \'br-lan\'\n\toption proto \'dhcp\'\n\tlist ipaddr \'10.10.10.1/24\'\n')"
if echo "$out" | grep -q "option proto 'static'" \
	&& echo "$out" | grep -q "option ipaddr '172.30.77.1'" \
	&& ! echo "$out" | grep -q "list ipaddr"; then
	ok "existing 25.12 list-ipaddr → static: list removed, lab IP written"
else
	bad "existing 25.12 → static failed: $out"
fi

# 7. Existing static with old ipaddr → static: old replaced by lab IP
out="$(transform_static $'config interface \'lan\'\n\toption device \'br-lan\'\n\toption proto \'static\'\n\toption ipaddr \'192.168.1.1\'\n\toption netmask \'255.255.255.0\'\n')"
if echo "$out" | grep -q "option ipaddr '172.30.77.1'" \
	&& ! echo "$out" | grep -q "192.168.1.1"; then
	ok "existing static → static: old ipaddr replaced by lab IP"
else
	bad "existing static → static replacement failed: $out"
fi

[[ "$fail" -eq 0 ]] && { echo "ALL PASSED"; exit 0; } || { echo "FAILURES" >&2; exit 1; }
