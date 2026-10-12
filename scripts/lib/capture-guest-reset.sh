#!/bin/sh
# Lab-only helper for docs screenshot capture (#15).
# Run on the QEMU guest via: ssh ... ash -s -- [allowlist...] < this file
#
# Deletes managed users that are not in the allowlist. last_admin is unwound
# with a registry + UNIX delete so empty-table shots are possible. Resets
# OpenWrt password policy and truncates the audit log so smoke names cannot
# appear in the gallery. Not a product CLI.
set -e

ALLOW="$*"

in_allow() {
	_want=$1
	for _a in $ALLOW; do
		[ "$_want" = "$_a" ] && return 0
	done
	return 1
}

safe() {
	_u=$1
	case "$_u" in
		''|*[!a-z0-9_-]*|[A-Z]*|[0-9]*|-*)
			echo "refusing unsafe username: $_u" >&2
			return 1
			;;
	esac
	case "$_u" in
		[a-z_]*) ;;
		*)
			echo "refusing unsafe username: $_u" >&2
			return 1
			;;
	esac
}

lab_unwind() {
	name=$1
	safe "$name" || return 1
	reg=/etc/usrmanage/users
	tmp="${reg}.tmp.$$"
	umask 077
	if [ -f "$reg" ]; then
		grep -vx "$name" "$reg" > "$tmp" || : > "$tmp"
		chmod 0640 "$tmp"
		chown 0:0 "$tmp" 2>/dev/null || true
		mv "$tmp" "$reg"
	fi
	deluser "$name" wheel >/dev/null 2>&1 || true
	if command -v userdel >/dev/null 2>&1; then
		userdel -r "$name" >/dev/null 2>&1 || userdel "$name" >/dev/null 2>&1 || true
	elif command -v deluser >/dev/null 2>&1; then
		deluser --remove-home "$name" >/dev/null 2>&1 || deluser "$name" >/dev/null 2>&1 || true
	fi
	delgroup "$name" >/dev/null 2>&1 || true
	rm -rf "/home/${name:?}" 2>/dev/null || true
}

command -v usrmanage >/dev/null || {
	echo "usrmanage missing on guest" >&2
	exit 1
}

usrmanage set-policy --preset openwrt >/dev/null

names=$(usrmanage list 2>/dev/null | awk '{print $1}')
for name in $names; do
	[ -n "$name" ] || continue
	case "$name" in
		\#*) continue ;;
	esac
	in_allow "$name" && continue
	safe "$name" || exit 1
	usrmanage set-luci-login "$name" --disable >/dev/null 2>&1 || true
	if usrmanage del "$name" --purge-home >/dev/null 2>&1; then
		continue
	fi
	lab_unwind "$name"
done

: > /var/log/usrmanage/audit.log
rm -f /var/log/usrmanage/audit.log.1
chmod 0640 /var/log/usrmanage/audit.log 2>/dev/null || true
chown 0:0 /var/log/usrmanage/audit.log 2>/dev/null || true
