#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Host-side smoke for CI / local checks.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)

skipped=0
test_skipped=0

run_test() {
	label=$1
	shift
	"$ROOT/scripts/test-activity.sh" "$label" "$@"
}

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
	run_test shellcheck "$ROOT/scripts/shellcheck.sh"
fi

if need python3 linkcheck "install python3"; then
	run_test linkcheck "$ROOT/scripts/usrmanage-linkcheck.sh"
fi

if need python3 package-layout "install python3"; then
	run_test package_layout "$ROOT/scripts/smoke-package-layout.sh"
fi

if need flock host-tests "brew install flock (Linux: util-linux)"; then
	run_test test_validators "$ROOT/tests/test_validators.sh"
	run_test test_mutators "$ROOT/tests/test_mutators.sh"
	run_test test_mutator_flows "$ROOT/tests/test_mutator_flows.sh"
	run_test test_policy "$ROOT/tests/test_policy.sh"
	run_test test_doctor "$ROOT/tests/test_doctor.sh"
	run_test test_luci_login "$ROOT/tests/test_luci_login.sh"
	run_test test_health "$ROOT/tests/test_health.sh"
	run_test test_read_paths "$ROOT/tests/test_read_paths.sh"
	run_test test_rpcd_list_acl "$ROOT/tests/test_rpcd_list_acl.sh"
	run_test test_rpcd_show_acl "$ROOT/tests/test_rpcd_show_acl.sh"
	run_test test_rpcd_session_sid "$ROOT/tests/test_rpcd_session_sid.sh"
	# Diagnostic page RPC coverage vs stock LuCI ACL fixtures (#156).
	if need python3 diagnostic-page-rpc-contract "install python3"; then
		run_test diagnostic_page_rpc_contract python3 "$ROOT/tests/test_diagnostic_page_rpc_contract.py"
	fi
	run_test test_phase1_foundation "$ROOT/tests/test_phase1_foundation.sh"
	run_test test_mutators_busybox_fallback "$ROOT/tests/test_mutators-busybox-fallback.sh"
	_password_log=$(mktemp)
	_password_rc=0
	run_test test_password_control "$ROOT/tests/test_password_control.sh" >"$_password_log" 2>&1 || _password_rc=$?
	cat "$_password_log"
	if grep -q '^skip: rpcd->CLI' "$_password_log"; then
		test_skipped=$((test_skipped + 1))
	fi
	rm -f "$_password_log"
	[ "$_password_rc" -eq 0 ] || exit "$_password_rc"
	run_test test_password_sha512_pin "$ROOT/tests/test_password_sha512_pin.sh"
	run_test test_password_prompt_echo "$ROOT/tests/test_password_prompt_echo.sh"
	run_test test_sdk_matrix_digests "$ROOT/tests/test_sdk_matrix_digests.sh"
	run_test test_sdk_matrix_release_inputs "$ROOT/tests/test_sdk_matrix_release_inputs.sh"
	run_test test_reproducible_build_contract "$ROOT/tests/test_reproducible_build_contract.sh"
	run_test test_download_gzip_gate "$ROOT/tests/test_download_gzip_gate.sh"
	run_test test_qemu_net_seed "$ROOT/tests/test_qemu_net_seed.sh"
	run_test test_qemu_smoke_contract "$ROOT/tests/test_qemu_smoke_contract.sh"
	run_test test_docs_screenshot_contract "$ROOT/tests/test_docs_screenshot_contract.sh"
fi

if need node theme-i18n-parity "install node"; then
	run_test usrmanage_theme node "$ROOT/tests/usrmanage-theme.test.js"
	run_test usrmanage_rpc_contract node "$ROOT/tests/usrmanage-rpc-contract.test.js"
	run_test usrmanage_health_refresh node "$ROOT/tests/usrmanage-health-refresh.test.js"
	run_test usrmanage_i18n node "$ROOT/tests/usrmanage-i18n.test.js"
	run_test usrmanage_parity node "$ROOT/tests/usrmanage-parity.test.js"
fi

echo ""
if [ "$skipped" -gt 0 ] || [ "$test_skipped" -gt 0 ]; then
	echo "Host smoke passed ($skipped stage(s) skipped for missing host tools; $test_skipped conditional test(s) skipped)."
else
	echo "Host smoke passed."
fi
echo "SDK matrix (optional local): ./scripts/docker-sdk.sh build-all"
echo "Repro gate: ./scripts/verify-reproducible-build.sh"
