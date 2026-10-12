#!/usr/bin/env bash
# Structural guards for repeat-safe QEMU smoke fixtures and page status checks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/scripts/qemu-smoke-usrmanage.sh"

# Keep the last-admin coverage while reusing/promoting umadmin on reruns.
grep -q 'usrmanage show umadmin --json' "$SRC"
grep -q 'usrmanage set-role umadmin --role admin' "$SRC"
grep -q 'usrmanage del umsmoke' "$SRC"
# Authentication redirects must not count as the requested LuCI page loading.
grep -q '\[\[ "\$HTTP_CODE" == 200 \]\]' "$SRC"
if grep -qE '200\|302\|303|302\|303\|200' "$SRC"; then
	echo "FAIL: smoke accepts a redirect as page success" >&2
	exit 1
fi
# Do not remove the explicit last-admin guard coverage.
grep -q 'last-admin guard blocks del umadmin' "$SRC"
echo "QEMU smoke contract tests passed (static only)"
