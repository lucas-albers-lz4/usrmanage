#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Timestamp test boundaries outside the checkout; never log command arguments/output.
set -u

if [ "$#" -lt 2 ]; then
	echo "usage: $0 LABEL COMMAND [ARG ...]" >&2
	exit 2
fi
label=$1
shift
log=${USRMANAGE_TEST_ACTIVITY_LOG:-/tmp/usrmanage-test-activity.log}

stamp() { date '+%Y-%m-%dT%H:%M:%S%z'; }
{
	printf '%s START %s\n' "$(stamp)" "$label"
	df -h "$(pwd)" 2>/dev/null | tail -n 1 | sed 's/^/DISK /'
	if [ -r /proc/meminfo ]; then
		awk '/^(MemAvailable|SwapFree):/ { print "RESOURCE " $0 }' /proc/meminfo
	fi
} >>"$log" 2>/dev/null

"$@"
rc=$?
printf '%s END %s exit=%s\n' "$(stamp)" "$label" "$rc" >>"$log"
exit "$rc"
