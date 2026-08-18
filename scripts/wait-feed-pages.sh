#!/usr/bin/env bash
# Wait until GitHub Pages feed URLs respond AND the feed manifest advertises
# the expected release tag (post-deploy).
#
#   ./scripts/wait-feed-pages.sh https://lucas-albers-lz4.github.io/usrmanage-packages v0.1.5
#
# The second argument (expected git tag) is required: reachability alone is not
# enough — the previous release's feed files would satisfy a bare HTTP probe
# immediately, and the QEMU feed smoke would then validate the OLD feed while
# the newly published one is broken. Polling manifest.json for the tag proves
# the fresh deploy has landed.
set -euo pipefail

BASE="${1:?usage: wait-feed-pages.sh BASE_URL EXPECTED_TAG}"
EXPECTED_TAG="${2:?usage: wait-feed-pages.sh BASE_URL EXPECTED_TAG}"
BASE="${BASE%/}"
MAX_WAIT="${FEED_PAGES_WAIT_SEC:-300}"
INTERVAL="${FEED_PAGES_WAIT_INTERVAL:-10}"

urls=(
	"${BASE}/24.10/Packages.gz"
	"${BASE}/25.12/all/packages.adb"
	# apk trust key: qemu-install-from-feed.sh fetches it for the 25.12 path
	"${BASE}/usrmanage-feed.rsa.pub"
	"${BASE}/public.key"
)

deadline=$((SECONDS + MAX_WAIT))
echo "Waiting for feed URLs under ${BASE} (max ${MAX_WAIT}s) and git_tag=${EXPECTED_TAG}..." >&2

while (( SECONDS < deadline )); do
	ok=1
	for u in "${urls[@]}"; do
		if ! curl -fsSIL "$u" >/dev/null 2>&1; then
			ok=0
			echo "  pending: $u" >&2
			break
		fi
	done
	if [[ $ok -eq 1 ]] && ! curl -fsSL "${BASE}/manifest.json" 2>/dev/null | grep -Fq "\"git_tag\": \"${EXPECTED_TAG}\""; then
		ok=0
		echo "  pending: manifest.json git_tag=${EXPECTED_TAG}" >&2
	fi
	if [[ $ok -eq 1 ]]; then
		echo "All feed URLs reachable; manifest advertises ${EXPECTED_TAG}." >&2
		exit 0
	fi
	sleep "$INTERVAL"
done

echo "Timeout waiting for GitHub Pages feed at ${BASE} (tag ${EXPECTED_TAG})" >&2
exit 1
