#!/bin/sh
# Shared helpers for the usrmanage host test suite (no root required).
# Portable stat: GNU stat(1) -c vs BSD stat(1) -f (macOS). Factor of the
# fallback idiom originally in tests/test_validators.sh (#75).

stat_mode() {
	# Portable octal file mode: GNU '%a' vs BSD '%OLp'. Normalized to no
	# leading zero so both platforms report e.g. 750 / 644 / 600 / 640.
	_m=$(stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1")
	printf '%s' "$_m" | sed 's/^0*//'
}

stat_owner() {
	# Portable numeric uid/gid: '%u %g' is valid for GNU -c and BSD -f.
	stat -c '%u %g' "$1" 2>/dev/null || stat -f '%u %g' "$1"
}
