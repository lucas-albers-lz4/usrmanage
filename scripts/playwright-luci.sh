#!/usr/bin/env bash
# Run LuCI Playwright e2e against a prepared QEMU lab.
# Does not boot QEMU — start the guest and install packages first.
#
#   ./scripts/playwright-luci.sh
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

HOST="${OPENWRT_HOST:-127.0.0.1}"
SSH_PORT="${OPENWRT_SSH_PORT:-2222}"
HTTP_PORT="${OWRT_HOSTFWD_HTTP:-8080}"
BASE_URL="${USRMANAGE_LUCI_URL:-http://${HOST}:${HTTP_PORT}}"

die() { echo "playwright-luci FAIL: $*" >&2; exit 1; }

if ! command -v node >/dev/null 2>&1; then
	die "node is required"
fi

if [[ ! -d "$ROOT/node_modules/@playwright/test" ]]; then
	echo "→ npm install (devDependencies)" >&2
	npm install
fi

if ! npx playwright --version >/dev/null 2>&1; then
	die "playwright CLI missing after npm install"
fi

echo "== checking QEMU lab at ${BASE_URL} (SSH ${HOST}:${SSH_PORT}) ==" >&2

if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o ConnectTimeout=5 -p "$SSH_PORT" "root@${HOST}" 'echo ok' >/dev/null 2>&1; then
	die "SSH unreachable — prepare/boot lab first (see docs/developer/testing.md)"
fi

if ! curl -fsS --connect-timeout 5 -o /dev/null "${BASE_URL}/cgi-bin/luci/" 2>/dev/null; then
	# LuCI may redirect; accept any HTTP response from the hostfwd port.
	code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 \
		"${BASE_URL}/cgi-bin/luci/" 2>/dev/null || true)
	[[ -n "$code" && "$code" != "000" ]] || die "LuCI unreachable at ${BASE_URL}"
fi

# Ensure Chromium for this Playwright version (cached installs return quickly).
npx playwright install chromium >/dev/null

export USRMANAGE_LUCI_URL="$BASE_URL"
echo "== playwright test (baseURL=${USRMANAGE_LUCI_URL}) ==" >&2
exec npx playwright test "$@"
