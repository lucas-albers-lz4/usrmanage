#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Frozen health projector for owned readonly LuCI (no secrets). BusyBox ash-safe.
# Sourced from usrmanage-lib.sh. Never pass through uci/iwinfo/wireless blobs.

# Byte-stable DRY_RUN fixture for host schema tests (revision 2).
USRMANAGE_HEALTH_DRY_RUN_JSON='{"ok":true,"hostname":"dry-run","release":"24.10.x","uptime_s":86400,"load":[0.01,0.02,0.00],"wan":{"up":true,"ipv4":true,"ipv6":true},"lan":{"up":true},"wifi":{"radios_up":2,"radios_total":2,"assoc_count":4},"dhcp_lease_count":6}'

um_health_unavailable() {
	printf '%s\n' '{"ok":false,"error":"health_unavailable"}'
}

um_health_bool_json() {
	case "$1" in
		1|true|yes|on) printf 'true' ;;
		*) printf 'false' ;;
	esac
}

um_health_uint() {
	case "$1" in
		''|*[!0-9]*) printf '0' ;;
		*) printf '%s' "$1" ;;
	esac
}

um_health_load_num() {
	# JSON number: digits with at most one dot. No exponent.
	_n=$1
	case "$_n" in
		''|.*|*.) printf '0' ; return 0 ;;
	esac
	case "$_n" in
		*[!0-9.]*) printf '0' ; return 0 ;;
	esac
	_dots=$(printf '%s' "$_n" | tr -cd '.' | wc -c | tr -d ' ')
	[ "$_dots" -le 1 ] || { printf '0'; return 0; }
	printf '%s' "$_n"
}

# Single JSON writer — extra keys cannot appear by construction.
um_health_json_emit() {
	# um_health_json_emit <hostname> <release> <uptime_s> <l1> <l2> <l3> \
	#   <wan_up> <wan_ipv4> <wan_ipv6> <lan_up> \
	#   <radios_up> <radios_total> <assoc_count> <dhcp_lease_count>
	_hn=$(printf '%s' "$1" | um_json_escape)
	_rel=$(printf '%s' "$2" | um_json_escape)
	_up=$(um_health_uint "$3")
	_l1=$(um_health_load_num "$4")
	_l2=$(um_health_load_num "$5")
	_l3=$(um_health_load_num "$6")
	_wup=$(um_health_bool_json "$7")
	_w4=$(um_health_bool_json "$8")
	_w6=$(um_health_bool_json "$9")
	_lup=$(um_health_bool_json "${10}")
	_ru=$(um_health_uint "${11}")
	_rt=$(um_health_uint "${12}")
	_ac=$(um_health_uint "${13}")
	_dc=$(um_health_uint "${14}")
	printf '{"ok":true,"hostname":"%s","release":"%s","uptime_s":%s,"load":[%s,%s,%s],"wan":{"up":%s,"ipv4":%s,"ipv6":%s},"lan":{"up":%s},"wifi":{"radios_up":%s,"radios_total":%s,"assoc_count":%s},"dhcp_lease_count":%s}\n' \
		"$_hn" "$_rel" "$_up" "$_l1" "$_l2" "$_l3" \
		"$_wup" "$_w4" "$_w6" "$_lup" \
		"$_ru" "$_rt" "$_ac" "$_dc"
}

# Project wifi integers from a hostile network.wireless / iwinfo blob.
# Uses jsonfilter for `.*.up` only; never concatenates the blob into output.
um_health_wifi_from_status_blob() {
	# stdin: JSON that may contain ssid/key/mac. stdout: "radios_up radios_total assoc_count"
	_blob=$(cat)
	_rt=0
	_ru=0
	_ac=0
	if command -v jsonfilter >/dev/null 2>&1 && [ -n "$_blob" ]; then
		_ups=$(printf '%s' "$_blob" | jsonfilter -e '@.*.up' 2>/dev/null || true)
		if [ -n "$_ups" ]; then
			_rt=$(printf '%s\n' "$_ups" | sed '/^$/d' | wc -l | tr -d ' ')
			_ru=$(printf '%s\n' "$_ups" | grep -cE '^(true|1)$' | tr -d ' ')
		fi
		# assoc_count: prefer explicit integer fields; never copy lists.
		_ac=$(printf '%s' "$_blob" | jsonfilter -e '@.*.assoc_count' 2>/dev/null | awk '
			BEGIN { n=0 }
			$1+0 == $1 { n += $1+0 }
			END { print n+0 }
		')
	fi
	unset _blob _ups
	printf '%s %s %s\n' "$(um_health_uint "$_ru")" "$(um_health_uint "$_rt")" "$(um_health_uint "$_ac")"
}

um_health_iface_flags() {
	# um_health_iface_flags <iface> → "up ipv4 ipv6" as 0/1. Never prints addresses.
	_if=$1
	_up=0
	_v4=0
	_v6=0
	if command -v ubus >/dev/null 2>&1; then
		_raw=$(ubus call "network.interface.${_if}" status 2>/dev/null) || _raw=
		if [ -n "$_raw" ] && command -v jsonfilter >/dev/null 2>&1; then
			_uv=$(printf '%s' "$_raw" | jsonfilter -e '@.up' 2>/dev/null || true)
			case "$_uv" in true|1) _up=1 ;; esac
			_a4=$(printf '%s' "$_raw" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null || true)
			[ -n "$_a4" ] && _v4=1
			_a6=$(printf '%s' "$_raw" | jsonfilter -e '@["ipv6-address"][0].address' 2>/dev/null || true)
			[ -z "$_a6" ] && _a6=$(printf '%s' "$_raw" | jsonfilter -e '@["ipv6-prefix-assignment"][0].address' 2>/dev/null || true)
			[ -n "$_a6" ] && _v6=1
			unset _a4 _a6 _uv
		fi
		unset _raw
	fi
	printf '%s %s %s\n' "$_up" "$_v4" "$_v6"
}

um_health_wifi_sysfs() {
	# Count radios / up / assoc from sysfs only. Station dir names are MACs —
	# count them, never print paths or names.
	_rt=0
	_ru=0
	_ac=0
	set +f
	for _phy in /sys/class/ieee80211/*; do
		[ -e "$_phy" ] || continue
		_rt=$((_rt + 1))
		_phy_up=0
		for _nd in "$_phy"/device/net/*; do
			[ -f "$_nd/operstate" ] || continue
			_st=$(cat "$_nd/operstate" 2>/dev/null || true)
			[ "$_st" = "up" ] && _phy_up=1
		done
		[ "$_phy_up" = "1" ] && _ru=$((_ru + 1))
	done
	for _st in /sys/kernel/debug/ieee80211/*/netdev:*/stations/*; do
		[ -d "$_st" ] || continue
		_ac=$((_ac + 1))
	done
	printf '%s %s %s\n' "$_ru" "$_rt" "$_ac"
}

um_health_dhcp_lease_count() {
	_f=/tmp/dhcp.leases
	[ -n "${USRMANAGE_DHCP_LEASES:-}" ] && _f=$USRMANAGE_DHCP_LEASES
	if [ -f "$_f" ]; then
		grep -c . "$_f" 2>/dev/null | tr -d ' '
	else
		printf '0'
	fi
}

um_health_gather_json() {
	_hn=
	_rel=
	if command -v ubus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
		_board=$(ubus call system board 2>/dev/null) || _board=
		if [ -n "$_board" ]; then
			_hn=$(printf '%s' "$_board" | jsonfilter -e '@.hostname' 2>/dev/null || true)
			_rel=$(printf '%s' "$_board" | jsonfilter -e '@.release.version' 2>/dev/null || true)
		fi
		unset _board
	fi
	[ -n "$_hn" ] || _hn=$(cat /proc/sys/kernel/hostname 2>/dev/null || true)
	[ -n "$_hn" ] || _hn=$(hostname 2>/dev/null || true)
	if [ -z "$_rel" ] && [ -f /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release 2>/dev/null || true
		_rel=${DISTRIB_RELEASE:-}
	fi
	[ -n "$_rel" ] || _rel=unknown
	[ -n "$_hn" ] || { um_health_unavailable; return 1; }

	_uptime_s=0
	if [ -r /proc/uptime ]; then
		_uptime_s=$(awk '{ printf "%d", $1+0 }' /proc/uptime 2>/dev/null || printf '0')
	fi

	_l1=0
	_l2=0
	_l3=0
	if [ -r /proc/loadavg ]; then
		_l1=$(awk '{ print $1 }' /proc/loadavg)
		_l2=$(awk '{ print $2 }' /proc/loadavg)
		_l3=$(awk '{ print $3 }' /proc/loadavg)
	fi

	_wan_up=0
	_wan_v4=0
	_wan_v6=0
	_lan_up=0
	_wf=$(um_health_iface_flags wan)
	# shellcheck disable=SC2086
	set -- $_wf
	_wan_up=$1
	_wan_v4=$2
	_wan_v6=$3
	_lf=$(um_health_iface_flags lan)
	# shellcheck disable=SC2086
	set -- $_lf
	_lan_up=$1

	_wifi=$(um_health_wifi_sysfs)
	# shellcheck disable=SC2086
	set -- $_wifi
	_ru=$1
	_rt=$2
	_ac=$3
	_dc=$(um_health_dhcp_lease_count)

	um_health_json_emit "$_hn" "$_rel" "$_uptime_s" "$_l1" "$_l2" "$_l3" \
		"$_wan_up" "$_wan_v4" "$_wan_v6" "$_lan_up" \
		"$_ru" "$_rt" "$_ac" "$_dc"
}

um_cmd_health() {
	if [ "${USRMANAGE_DRY_RUN:-0}" = "1" ]; then
		printf '%s\n' "$USRMANAGE_HEALTH_DRY_RUN_JSON"
		return 0
	fi
	um_health_gather_json || um_health_unavailable
}
