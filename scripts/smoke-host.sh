#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Host-side smoke for CI / local checks.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

"$ROOT/scripts/shellcheck.sh"
"$ROOT/scripts/smoke-package-layout.sh"
"$ROOT/tests/test_validators.sh"
"$ROOT/tests/test_mutators.sh"

if command -v node >/dev/null 2>&1; then
	node "$ROOT/tests/usrmanage-theme.test.js"
	node "$ROOT/tests/usrmanage-i18n.test.js"
else
	echo "warn: node not found; skipping theme/i18n tests" >&2
fi

echo ""
echo "Host smoke passed."
echo "SDK matrix (optional local): ./scripts/docker-sdk.sh build-all"
echo "Repro gate: ./scripts/verify-reproducible-build.sh"
