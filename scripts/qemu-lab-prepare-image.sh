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

if [[ -f "$MNT/etc/config/network" ]]; then
	if [[ "$OWRT_LAB_NET_MODE" == "dhcp" ]]; then
		# Match lan section through next config block or EOF. Handles both
		# classic option ipaddr/netmask and 25.12 list ipaddr 'x.x.x.x/nn'.
		awk '
			BEGIN { in_lan = 0 }
			/^config / {
				if (in_lan) in_lan = 0
				if ($0 ~ /^config interface .lan./) in_lan = 1
			}
			{
				if (in_lan) {
					if ($0 ~ /option proto /) {
						print "\toption proto '\''dhcp'\''"
						next
					}
					if ($0 ~ /option ipaddr /) next
					if ($0 ~ /option netmask /) next
					if ($0 ~ /list ipaddr /) next
					if ($0 ~ /option ip6assign /) next
				}
				print
			}
		' "$MNT/etc/config/network" > "$MNT/etc/config/network.tmp"
		mv "$MNT/etc/config/network.tmp" "$MNT/etc/config/network"
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
