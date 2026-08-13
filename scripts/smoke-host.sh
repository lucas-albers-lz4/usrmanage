#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Host-side smoke for CI / local checks.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

skipped=0

# Hermetic shell test stages rely on USRMANAGE_* path overrides; those
# overrides are honored only when the test-only gate is set (issue #72 / #65).
export USRMANAGE_TEST_OVERRIDES=1

# need <tool> <stage> <hint> — run the stage only if <tool> exists; otherwise
# skip it with a clear one-line reason (partial-green stays obvious below).
need() {
	if command -v "$1" >/dev/null 2>&1; then
		return 0
	fi
	echo "skip: $2 (missing host tool: $1 — $3)" >&2
	skipped=$((skipped + 1))
	return 1
}

if need shellcheck shellcheck "e.g. brew install shellcheck"; then
	"$ROOT/scripts/shellcheck.sh"
fi

if need python3 linkcheck "install python3"; then
	"$ROOT/scripts/usrmanage-linkcheck.sh"
fi

if need python3 package-layout "install python3"; then
	"$ROOT/scripts/smoke-package-layout.sh"
fi

if need flock host-tests "brew install flock (Linux: util-linux)"; then
	"$ROOT/tests/test_validators.sh"
	"$ROOT/tests/test_mutators.sh"
	"$ROOT/tests/test_doctor.sh"
	"$ROOT/tests/test_luci_login.sh"
	"$ROOT/tests/test_phase1_foundation.sh"
	"$ROOT/tests/test_mutators-busybox-fallback.sh"
	"$ROOT/tests/test_password_control.sh"
	"$ROOT/tests/test_sdk_matrix_digests.sh"
fi

if need node theme-i18n-parity "install node"; then
	node "$ROOT/tests/usrmanage-theme.test.js"
	node "$ROOT/tests/usrmanage-i18n.test.js"
	node "$ROOT/tests/usrmanage-parity.test.js"
fi

echo ""
if [ "$skipped" -gt 0 ]; then
	echo "Host smoke passed ($skipped stage(s) skipped for missing host tools)."
else
	echo "Host smoke passed."
fi
echo "SDK matrix (optional local): ./scripts/docker-sdk.sh build-all"
echo "Repro gate: ./scripts/verify-reproducible-build.sh"
