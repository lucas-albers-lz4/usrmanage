#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Host-side smoke for CI / local checks.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

"$ROOT/scripts/shellcheck.sh"
"$ROOT/scripts/smoke-package-layout.sh"
"$ROOT/tests/test_validators.sh"
"$ROOT/tests/test_mutators.sh"
"$ROOT/tests/test_phase1_foundation.sh"
"$ROOT/tests/test_mutators-busybox-fallback.sh"

if command -v node >/dev/null 2>&1; then
	node "$ROOT/tests/usrmanage-theme.test.js"
	node "$ROOT/tests/usrmanage-i18n.test.js"
	node "$ROOT/tests/usrmanage-parity.test.js"
else
	echo "warn: node not found; skipping theme/i18n/parity tests" >&2
fi

echo ""
echo "Host smoke passed."
echo "SDK matrix (optional local): ./scripts/docker-sdk.sh build-all"
echo "Repro gate: ./scripts/verify-reproducible-build.sh"
