#!/usr/bin/env bash
# One-time tweaks to OpenWrt x86 disk for QEMU user-net + hostfwd.
#
# - HTTP-only uhttpd
# - rfc1918_filter off
# - syn_flood off / defaults input ACCEPT (lab only)
# - clear root password
# - network.lan.proto=dhcp for slirp
#
# Usage: sudo OWRT_IMG=lab/images/openwrt-x86-64-24.10.8.img ./scripts/qemu-lab-prepare-image.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OWRT_LAB_NET_MODE="${OWRT_LAB_NET_MODE:-dhcp}"
# shellcheck source=lib/qemu-lab-net.sh
source "${ROOT}/scripts/lib/qemu-lab-net.sh"
IMG="${OWRT_IMG:-${ROOT}/lab/images/openwrt-x86-64-24.10.8.img}"
MNT="/mnt/owrt-usrmanage-lab"
LAB_MASK="${OWRT_LAB_SUBNET#*/}"

[[ -f "$IMG" ]] || { echo "missing image: $IMG" >&2; exit 1; }
[[ "$(id -u)" -eq 0 ]] || { echo "run as root (needs loop mount)" >&2; exit 1; }

LOOP="$(losetup -fP --show "$IMG")"
cleanup() {
	umount "$MNT" 2>/dev/null || true
	losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

if [[ -b "${LOOP}p2" ]] && command -v e2fsck >/dev/null 2>&1; then
	e2fsck -fy "${LOOP}p2" >/dev/null 2>&1 || true
fi

mkdir -p "$MNT"
mount -o rw "${LOOP}p2" "$MNT"

if [[ -f "$MNT/etc/config/uhttpd" ]]; then
	sed -i "s/option rfc1918_filter '1'/option rfc1918_filter '0'/" "$MNT/etc/config/uhttpd"
	sed -i "/listen_https/d; /option cert/d; /option key/d" "$MNT/etc/config/uhttpd"
fi
if [[ -f "$MNT/etc/config/firewall" ]]; then
	sed -i "s/option syn_flood '1'/option syn_flood '0'/" "$MNT/etc/config/firewall"
	sed -i '/^config defaults$/,/^$/{
		s/^\(\t*option syn_flood\)[[:space:]]*1$/\1\t0/
		s/^\(\t*option input\)[[:space:]]*REJECT$/\1\tACCEPT/
	}' "$MNT/etc/config/firewall"
fi

if [[ -f "$MNT/etc/shadow" ]]; then
	sed -i 's/^root:[^:]*:/root::/' "$MNT/etc/shadow"
fi
if [[ -f "$MNT/etc/config/dropbear" ]]; then
	grep -q "option PasswordAuth" "$MNT/etc/config/dropbear" \
		|| echo "	option PasswordAuth 'on'" >>"$MNT/etc/config/dropbear"
	grep -q "option RootPasswordAuth" "$MNT/etc/config/dropbear" \
		|| echo "	option RootPasswordAuth 'on'" >>"$MNT/etc/config/dropbear"
	sed -i "s/option PasswordAuth 'off'/option PasswordAuth 'on'/" "$MNT/etc/config/dropbear"
	sed -i "s/option RootPasswordAuth 'off'/option RootPasswordAuth 'on'/" "$MNT/etc/config/dropbear"
fi

# LAN: DHCP for default slirp, or static when OWRT_LAB_NET_MODE=static.
# OpenWrt x86 combined images may omit /etc/config/network until first boot
# (verified: 24.10.8 combined-efi image has no network file). Seed lab
# defaults so slirp hostfwd can reach the guest — without a LAN DHCP address
# (10.0.2.15) or a matching static IP, SSH hostfwd times out on banner
# exchange. Seed mode-aware: DHCP or static per OWRT_LAB_NET_MODE.
# Lan proto: dhcp (default slirp) or static (OWRT_LAB_NET_MODE=static).
_lan_proto='dhcp'
[[ "$OWRT_LAB_NET_MODE" == "static" ]] && _lan_proto='static'
if [[ ! -f "$MNT/etc/config/network" ]]; then
	cat >"$MNT/etc/config/network" <<EOF
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
	if [[ "$OWRT_LAB_NET_MODE" == "static" ]]; then
		cat >>"$MNT/etc/config/network" <<EOF
	option ipaddr '${OWRT_LAB_IP}'
	option netmask '255.255.255.0'
EOF
	fi
	echo "	option ip6assign '60'" >>"$MNT/etc/config/network"
elif [[ -f "$MNT/etc/config/network" ]]; then
	if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
		# Match lan section through the next config block (not just first
		# blank line — 25.12 uses list ipaddr, and sections may not end on a
		# blank line). Remove static ipaddr/netmask/list-ipaddr, force dhcp.
		awk '
			BEGIN { in_lan = 0 }
			/^config / {
				if (in_lan) in_lan = 0
				if ($0 ~ /^config interface .lan./) in_lan = 1
			}
			{
				if (in_lan) {
					if ($0 ~ /option proto /) {
						print "	option proto '\''dhcp'\''"
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
		' "$MNT/etc/config/network" > "$MNT/etc/config/network.tmp"
		mv "$MNT/etc/config/network.tmp" "$MNT/etc/config/network"
	else
		# Static mode on an existing file: rewrite the lan section to a
		# deterministic single static address. Remove ALL prior address forms
		# (option ipaddr/netmask/gateway AND 25.12 list ipaddr), then append
		# the lab IP + netmask. A DHCP config left untouched would have no
		# static address; a retained list ipaddr would keep a stale address.
		awk -v lab_ip="$OWRT_LAB_IP" '
			BEGIN { in_lan = 0; wrote_static = 0 }
			/^config / {
				if (in_lan && !wrote_static) {
					print "	option ipaddr '\''" lab_ip "'\''"
					print "	option netmask '\''255.255.255.0'\''"
					wrote_static = 1
				}
				if (in_lan) in_lan = 0
				if ($0 ~ /^config interface .lan./) in_lan = 1
			}
			{
				if (in_lan) {
					if ($0 ~ /option proto /) { print "	option proto '\''static'\''"; next }
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
					print "	option ipaddr '\''" lab_ip "'\''"
					print "	option netmask '\''255.255.255.0'\''"
				}
			}
		' "$MNT/etc/config/network" > "$MNT/etc/config/network.tmp"
		mv "$MNT/etc/config/network.tmp" "$MNT/etc/config/network"
	fi
fi
if [[ -f "$MNT/etc/config/network" ]]; then
	_lan_block="$(sed -n "/^config interface 'lan'/,/^config /p" "$MNT/etc/config/network")"
	if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]] \
		&& ! printf '%s\n' "$_lan_block" | grep -qE "^[[:space:]]+option proto 'dhcp'"; then
		echo "error: failed to set network.lan proto=dhcp on $IMG" >&2
		exit 1
	fi
	if [[ "$OWRT_LAB_NET_MODE" == "static" ]] \
		&& { ! printf '%s\n' "$_lan_block" | grep -qE "^[[:space:]]+option proto 'static'" \
			|| ! printf '%s\n' "$_lan_block" | grep -qE "^[[:space:]]+option ipaddr '${OWRT_LAB_IP}'"; }; then
		echo "error: failed to set network.lan proto=static + ${OWRT_LAB_IP} on $IMG" >&2
		exit 1
	fi
fi

if [[ ! -f "$MNT/etc/init.d/qemu-lab-ssh" ]]; then
	cat >"$MNT/etc/init.d/qemu-lab-ssh" <<'EOS'
#!/bin/sh /etc/rc.common
START=99
start() {
	/etc/init.d/dropbear start
}
EOS
	chmod +x "$MNT/etc/init.d/qemu-lab-ssh"
	ln -sf ../init.d/qemu-lab-ssh "$MNT/etc/rc.d/S99qemu-lab-ssh"
fi

if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
	echo "Prepared $IMG for QEMU lab (LAN dhcp + slirp hostfwd)."
else
	echo "Prepared $IMG for QEMU lab (LAN ${OWRT_LAB_IP}/${LAB_MASK})."
fi
