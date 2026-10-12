#!/usr/bin/env bash
# Host tests for pinned SDK image digest resolution (sdk_matrix_pull / sdk_matrix_image_digest)
# and the feed manifest sdk_images section (issue #71 R4). Docker is mocked — no daemon needed.
# shellcheck disable=SC2015  # deliberate ok()/bad() test idiom (A && ok || bad)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
# shellcheck source=../scripts/lib/sdk-matrix.sh
source "$ROOT/scripts/lib/sdk-matrix.sh"
# shellcheck disable=SC1091
# shellcheck source=../scripts/lib/feed-publish.sh
source "$ROOT/scripts/lib/feed-publish.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

# R7 host proof (no docker daemon): first secret-touching SDK use pins, and
# every container that bind-mounts a signing secret is --network none.
if grep -qE '^[[:space:]]*sdk_matrix_pull_and_pin ' "$ROOT/scripts/validate-feed-keys.sh" \
	&& ! grep -qE '^[[:space:]]*sdk_matrix_resolve ' "$ROOT/scripts/validate-feed-keys.sh"; then
	ok "R7: validate-feed-keys pins SDK (no resolve-only pull)"
else
	bad "R7: validate-feed-keys.sh must call pull_and_pin, not resolve"
fi
if grep -q -- '--network none' "$ROOT/scripts/validate-feed-keys.sh"; then
	ok "R7: validate-feed-keys docker run is --network none"
else
	bad "R7: validate-feed-keys.sh docker run missing --network none"
fi
_secret_runs="$(grep -c -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" || true)"
if [[ "$_secret_runs" -eq 2 ]] \
	&& grep -A8 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q 'opkg-secret.key' \
	&& grep -A8 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q 'apk-secret.rsa' \
	&& grep -A8 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q '/feed/tools' \
	&& grep -A8 -- '--network none --user root' "$ROOT/scripts/lib/feed-publish.sh" | grep -q '/feed/lib' \
	&& grep -q 'sdk-export' "$ROOT/docker-compose.yml" \
	&& grep -q 'sdk-export' "$ROOT/scripts/lib/feed-publish.sh"; then
	ok "R7: opkg/apk secret runs are --network none with /feed/tools + /feed/lib (sdk-export)"
else
	bad "R7: feed-publish secret mounts must use --network none with sdk-export tools/lib (got $_secret_runs)"
fi

# Issue #159: feed signing keys must not be on disk during SDK build cells
# (sdk service bind-mounts the workspace as root).
_pub_wf="$ROOT/.github/workflows/publish-packages.yml"
_build_ln=$(grep -nF './scripts/docker-sdk.sh build' "$_pub_wf" | tail -1 | cut -d: -f1)
_repro_ln=$(grep -nF './scripts/verify-reproducible-build.sh' "$_pub_wf" | tail -1 | cut -d: -f1)
_keys_ln=$(grep -n 'feed_keys_write_from_env' "$_pub_wf" | head -1 | cut -d: -f1)
_sdk_done=0
if [[ -n "$_build_ln" && -n "$_repro_ln" ]]; then
	if [[ "$_build_ln" -gt "$_repro_ln" ]]; then
		_sdk_done=$_build_ln
	else
		_sdk_done=$_repro_ln
	fi
fi
if [[ -n "$_build_ln" && -n "$_repro_ln" && -n "$_keys_ln" &&
      "$_keys_ln" -gt "$_build_ln" && "$_keys_ln" -gt "$_repro_ln" ]]; then
	ok "publish workflow: signing keys written after SDK builds + repro gate (#159)"
else
	bad "publish workflow: feed_keys_write_from_env must follow last SDK build and reproducible gate"
fi
# Key material / writers must not appear before SDK work finishes (static
# absence proof — no earlier step may name or write these paths).
_pre_key_hit=0
if [[ "$_sdk_done" -gt 0 ]]; then
	while IFS=: read -r _ln _rest; do
		[[ -n "$_ln" ]] || continue
		if [[ "$_ln" -le "$_sdk_done" ]]; then
			_pre_key_hit=1
			bad "publish workflow: key material before SDK done (line $_ln): ${_rest:0:80}"
		fi
	done < <(grep -nE 'feed_keys_write_from_env|opkg-secret\.key|apk-secret\.rsa' "$_pub_wf" || true)
fi
if [[ "$_sdk_done" -gt 0 && "$_pre_key_hit" -eq 0 ]]; then
	ok "publish workflow: no key paths/writers before SDK builds + repro (#159)"
elif [[ "$_sdk_done" -eq 0 ]]; then
	bad "publish workflow: could not locate SDK build/repro steps for key-absence proof"
fi

# #161 fold: post-key staging must never launch the workspace-mounted `sdk`
# service (container root could read signing keys from the workspace). The
# readiness/mkhash probes use the volume-only `sdk-export` service instead —
# assert no caller of the workspace-mounted sdk_matrix_compose_run helper.
if grep -q 'sdk_matrix_compose_run' "$ROOT/scripts/lib/feed-publish.sh"; then
	bad "feed-publish.sh must not call the workspace-mounted sdk compose helper post-key (#161)"
else
	ok "feed-publish.sh has no workspace-mounted sdk compose helper call (#161)"
fi
if awk '/^sdk_matrix_feeds_ready\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" | grep -q 'sdk_matrix_compose_run'; then
	bad "sdk_matrix_feeds_ready must not call the workspace-mounted sdk compose helper (#161)"
elif awk '/^sdk_matrix_feeds_ready\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" | grep -q 'sdk-export'; then
	ok "sdk_matrix_feeds_ready probes via sdk-export, not the workspace-mounted sdk service (#161)"
else
	bad "sdk_matrix_feeds_ready must probe via sdk-export only, never the workspace-mounted sdk service (#161)"
fi
# The lock hash must be passed INTO the probe container explicitly: a bare
# `VAR=x docker compose run` prefix only feeds Compose file interpolation
# (like ${OWRT_SDK_IMAGE}), it does not reach the container env (luna r2).
if awk '/^sdk_matrix_feeds_ready\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" | grep -q -- '-e "LOCK_SHA='; then
	ok "sdk_matrix_feeds_ready passes LOCK_SHA into the probe container (-e) (#161)"
else
	bad "sdk_matrix_feeds_ready must pass LOCK_SHA via docker compose run -e (#161)"
fi
# The feeds cache holds usrmanage as an absolute src-link into the workspace,
# which the workspace-free probe cannot resolve: the src-link TARGET content
# (package Makefiles) must be checked host-side, and the cache side must check
# the link's existence, not its resolved target (luna r3).
if awk '/^sdk_matrix_feeds_ready\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" | grep -q 'openwrt-feed/usrmanage/Makefile' \
	&& awk '/^sdk_matrix_feeds_ready\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" | grep -q -- '\[ -L /builder/feeds/usrmanage \]'; then
	ok "sdk_matrix_feeds_ready handles the src-link cache without a workspace mount (#161)"
else
	bad "sdk_matrix_feeds_ready must check the src-link target host-side and the link in-container (#161)"
fi
# The probe must initialize the cache dirs BEFORE bind-mounting them — docker
# -v auto-creates missing host dirs as root, breaking a clean local build
# (luna r4), and the mount must use the absolute cache path cache_dirs sets.
# ORDER matters: both tokens existing is not enough (luna r5).
_init_ln="$(awk '/^sdk_matrix_feeds_ready\(\)/,/^}/ { if ($0 ~ /sdk_matrix_cache_dirs/) { print NR; exit } }' "$ROOT/scripts/lib/sdk-matrix.sh")"
_mount_ln="$(awk '/^sdk_matrix_feeds_ready\(\)/,/^}/ { if ($0 ~ /SDK_MATRIX_FEEDS_CACHE}:\/builder\/feeds/) { print NR; exit } }' "$ROOT/scripts/lib/sdk-matrix.sh")"
if [[ -n "$_init_ln" && -n "$_mount_ln" && "$_init_ln" -lt "$_mount_ln" ]]; then
	ok "sdk_matrix_feeds_ready initializes the cache before the probe mount (#161)"
else
	bad "sdk_matrix_feeds_ready must initialize cache dirs BEFORE bind-mounting (init line ${_init_ln:-?}, mount line ${_mount_ln:-?}) (#161)"
fi
# sdk_matrix_copy_out launches the `sdk` service directly — it must pass the
# same normalized cache vars as the build path and normalize BEFORE the
# compose invocation (luna r6 Minor, r7: both vars + order).
if awk '/^sdk_matrix_copy_out\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" | grep -q 'OWRT_SDK_DL_CACHE=' \
	&& awk '/^sdk_matrix_copy_out\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" | grep -q 'OWRT_SDK_FEEDS_CACHE='; then
	ok "sdk_matrix_copy_out passes both normalized cache vars (#161)"
else
	bad "sdk_matrix_copy_out must pass both normalized cache vars (#161)"
fi
_cinit_ln="$(awk '/^sdk_matrix_copy_out\(\)/,/^}/ { if ($0 ~ /sdk_matrix_cache_dirs/) { print NR; exit } }' "$ROOT/scripts/lib/sdk-matrix.sh")"
_crun_ln="$(awk '/^sdk_matrix_copy_out\(\)/,/^}/ { if ($0 ~ /docker compose run/) { print NR; exit } }' "$ROOT/scripts/lib/sdk-matrix.sh")"
if [[ -n "$_cinit_ln" && -n "$_crun_ln" && "$_cinit_ln" -lt "$_crun_ln" ]]; then
	ok "sdk_matrix_copy_out normalizes cache before the compose run (#161)"
else
	bad "sdk_matrix_copy_out must normalize cache BEFORE the compose run (#161)"
fi
# Cache init must fail closed: mkdir -p failures are explicitly returned
# (feeds_ready runs in if/! /|| contexts where errexit is suppressed — luna r8),
# and feeds_ready must PROPAGATE the cache_dirs failure (luna r9).
if awk '/^sdk_matrix_cache_dirs\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" \
	| grep -q "mkdir -p \"\$SDK_MATRIX_DL_CACHE\" \"\$SDK_MATRIX_FEEDS_CACHE\" || return 1"; then
	ok "sdk_matrix_cache_dirs fails closed on mkdir failure (#161)"
else
	bad "sdk_matrix_cache_dirs must return 1 when mkdir -p fails (#161)"
fi
if awk '/^sdk_matrix_feeds_ready\(\)/,/^}/' "$ROOT/scripts/lib/sdk-matrix.sh" \
	| grep -q "sdk_matrix_cache_dirs \"\$root\" \"\$SDK_MATRIX_VERSION_LABEL\" || return 1"; then
	ok "sdk_matrix_feeds_ready propagates cache-init failure (#161)"
else
	bad "sdk_matrix_feeds_ready must fail closed when cache init fails (#161)"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# #194: only supported release keys and their pinned point versions validate.
for version in 24.10 24.10.8 25.12 25.12.5; do
	sdk_matrix_validate_version "$version" || bad "supported version rejected: $version"
done
for version in 23.05 snapshot nonsense 25.12.99 24.10.7; do
	if sdk_matrix_validate_version "$version" >/dev/null 2>&1; then
		bad "unsupported version accepted: $version"
	else
		ok "unsupported version rejected: $version"
	fi
done

make_ipk_fixture() {
	local name="$1" version="$2" arch="$3" output="$4" stage
	stage="$TMP/ipk-$name"
	rm -rf "$stage"
	mkdir -p "$stage/control"
	printf 'Package: %s\nVersion: %s\nArchitecture: %s\n' "$name" "$version" "$arch" > "$stage/control/control"
	[ -z "${5:-}" ] || printf 'Description: %s\n' "$5" >> "$stage/control/control"
	tar -czf "$stage/control.tar.gz" -C "$stage/control" .
	printf '2.0\n' > "$stage/debian-binary"
	tar -czf "$output" -C "$stage" debian-binary control.tar.gz
}
make_apk_fixture() {
	local name="$1" version="$2" arch="$3" output="$4"
	# The real ADB binary format is decoded by the pinned SDK apk tool. Host
	# unit tests stub that boundary and exercise the identity validation.
	printf 'ADBd host fixture\n' > "$output"
	printf '{"info":{"name":"%s","version":"%s","arch":"%s"}}\n' \
		"$name" "$version" "$arch" > "${output}.metadata.json"
}
# ShellCheck cannot see this override invoked indirectly from the validator.
# shellcheck disable=SC2317,SC2329
sdk_matrix_read_apk_metadata() {
	cat "${1}.metadata.json"
}

# #185/#186: identity, version, architecture, package format, and complete set.
grep -q 'adbdump --format json' "$ROOT/scripts/lib/sdk-matrix.sh" \
	&& ok "APK validation uses the SDK ADB metadata reader" \
	|| bad "APK validation must use apk adbdump, not tar/.PKGINFO assumptions"
_ipk_dir="$TMP/pkg-ipk"
mkdir -p "$_ipk_dir"
_expected_usr="$(sdk_matrix_expected_package_version usrmanage)"
_expected_luci="$(sdk_matrix_expected_package_version luci-app-usrmanage)"
make_ipk_fixture usrmanage "$_expected_usr" all "$_ipk_dir/usrmanage_${_expected_usr}_all.ipk"
make_ipk_fixture luci-app-usrmanage "$_expected_luci" all "$_ipk_dir/luci-app-usrmanage_${_expected_luci}_all.ipk"
sdk_matrix_validate_package_dir "$_ipk_dir" 24.10 \
	&& ok "24.10 artifact set validates both opkg packages" \
	|| bad "24.10 artifact set validation failed"
make_ipk_fixture usrmanage 0.1.1-r1 all "$_ipk_dir/usrmanage_0.1.1-r1_all.ipk"
if sdk_matrix_validate_package_dir "$_ipk_dir" 24.10 >/dev/null 2>&1; then
	bad "stale duplicate package version was accepted"
else
	ok "stale package duplicate rejected"
fi
rm -f "$_ipk_dir/usrmanage_0.1.1-r1_all.ipk" "$_ipk_dir/luci-app-usrmanage_"*.ipk
if sdk_matrix_validate_package_dir "$_ipk_dir" 24.10 >/dev/null 2>&1; then
	bad "missing mandatory LuCI package was accepted"
else
	ok "missing mandatory package rejected"
fi

_apk_dir="$TMP/pkg-apk"
mkdir -p "$_apk_dir"
make_apk_fixture usrmanage "$_expected_usr" noarch "$_apk_dir/usrmanage-${_expected_usr}.apk"
make_apk_fixture luci-app-usrmanage "$_expected_luci" noarch "$_apk_dir/luci-app-usrmanage-${_expected_luci}.apk"
sdk_matrix_validate_package_dir "$_apk_dir" 25.12 \
	&& ok "25.12 artifact set validates both APK packages" \
	|| bad "25.12 artifact set validation failed"
make_apk_fixture usrmanage "$_expected_usr" x86_64 "$_apk_dir/usrmanage-${_expected_usr}.apk"
if sdk_matrix_validate_package_dir "$_apk_dir" 25.12 >/dev/null 2>&1; then
	bad "architecture-mismatched APK was accepted"
else
	ok "architecture-mismatched APK rejected"
fi

# #185: SDK copy-out starts from a fresh destination and fails if export fails.
make_ipk_fixture usrmanage "$_expected_usr" all "$_ipk_dir/usrmanage_${_expected_usr}_all.ipk"
make_ipk_fixture luci-app-usrmanage "$_expected_luci" all "$_ipk_dir/luci-app-usrmanage_${_expected_luci}_all.ipk"
_copy_root="$TMP/copy-root"
mkdir -p "$_copy_root/scripts/lib" "$_copy_root/openwrt-feed/usrmanage" \
	"$_copy_root/openwrt-feed/luci-app-usrmanage" "$_copy_root/out/x86_64/24.10.8/usrmanage" "$TMP/copy-bin"
cp "$ROOT/scripts/lib/sdk-matrix.sh" "$_copy_root/scripts/lib/sdk-matrix.sh"
cp "$ROOT/openwrt-feed/usrmanage/Makefile" "$_copy_root/openwrt-feed/usrmanage/Makefile"
cp "$ROOT/openwrt-feed/luci-app-usrmanage/Makefile" "$_copy_root/openwrt-feed/luci-app-usrmanage/Makefile"
cp "$_ipk_dir/usrmanage_${_expected_usr}_all.ipk" "$_copy_root/openwrt-feed/usrmanage-fixture.ipk"
cp "$_ipk_dir/luci-app-usrmanage_${_expected_luci}_all.ipk" "$_copy_root/openwrt-feed/luci-app-fixture.ipk"
cat > "$TMP/copy-bin/docker" <<'DOCKER'
#!/bin/sh
[ "${COPY_OUT_FAIL:-0}" = 0 ] || exit 42
_dest="${COPY_OUT_ROOT}/x86_64/24.10.8/usrmanage"
mkdir -p "$_dest"
cp "${COPY_OUT_PACKAGES}/usrmanage_${COPY_OUT_VERSION}_all.ipk" "$_dest/"
cp "${COPY_OUT_PACKAGES}/luci-app-usrmanage_${COPY_OUT_VERSION}_all.ipk" "$_dest/"
DOCKER
chmod +x "$TMP/copy-bin/docker"
mkdir -p "$_copy_root/out/x86_64/24.10.8/usrmanage"
touch "$_copy_root/out/x86_64/24.10.8/usrmanage/stale.ipk"
if (
	# These exports intentionally configure isolated test subshells.
	# shellcheck disable=SC2030,SC2031
	export PATH="$TMP/copy-bin:$PATH"
	# shellcheck disable=SC2030,SC2031
	export COPY_OUT_ROOT="$_copy_root/out" COPY_OUT_PACKAGES="$_ipk_dir" COPY_OUT_VERSION="$_expected_usr"
	# shellcheck disable=SC1091
	source "$_copy_root/scripts/lib/sdk-matrix.sh"
	sdk_matrix_resolve x86-64 24.10
	sdk_matrix_copy_out
	[[ ! -e "$_copy_root/out/x86_64/24.10.8/usrmanage/stale.ipk" ]] || exit 1
	[[ -f "$_copy_root/out/x86_64/24.10.8/usrmanage/usrmanage_${_expected_usr}_all.ipk" ]] || exit 1
); then
	ok "SDK copy-out prunes stale destination and validates fresh output"
else
	bad "SDK copy-out did not export a fresh package set"
fi
(
	# These exports intentionally configure an isolated test subshell.
	# shellcheck disable=SC2030,SC2031
	export PATH="$TMP/copy-bin:$PATH"
	# shellcheck disable=SC2030,SC2031
	export COPY_OUT_ROOT="$_copy_root/out" COPY_OUT_PACKAGES="$_ipk_dir" COPY_OUT_VERSION="$_expected_usr" COPY_OUT_FAIL=1
	# shellcheck disable=SC1091
	source "$_copy_root/scripts/lib/sdk-matrix.sh"
	sdk_matrix_resolve x86-64 24.10
	sdk_matrix_copy_out
) >/dev/null 2>&1 && {
	bad "SDK copy-out accepted failed export"
} || {
	[ ! -e "$_copy_root/out/x86_64/24.10.8/usrmanage/usrmanage_${_expected_usr}_all.ipk" ] \
		&& ok "SDK copy-out fails closed and leaves no stale artifact" \
		|| bad "SDK copy-out left artifact after failed export"
}

# #184/#187: failure propagation and hashing must follow the selected target arch.
_repo_root="$ROOT"
_sdk_resolve_original="$(declare -f sdk_matrix_resolve)"
_feeds_ready_original="$(declare -f sdk_matrix_feeds_ready)"
_make_original="$(declare -f sdk_matrix_make)"
_clean_original="$(declare -f sdk_matrix_clean_package)"
_copy_original="$(declare -f sdk_matrix_copy_out)"
_epoch_original="$(declare -f sdk_matrix_source_date_epoch)"
# shellcheck disable=SC1091
source "$ROOT/scripts/verify-reproducible-build.sh"
VERIFY_ROOT="$TMP/verify-root"
mkdir -p "$VERIFY_ROOT/out/x86_64/24.10.8/usrmanage" \
	"$VERIFY_ROOT/out/aarch64_generic/24.10.8/usrmanage" "$VERIFY_ROOT/scripts"
cp "$_ipk_dir/usrmanage_${_expected_usr}_all.ipk" \
	"$_ipk_dir/luci-app-usrmanage_${_expected_luci}_all.ipk" \
	"$VERIFY_ROOT/out/x86_64/24.10.8/usrmanage/"
cp "$_ipk_dir/usrmanage_${_expected_usr}_all.ipk" \
	"$_ipk_dir/luci-app-usrmanage_${_expected_luci}_all.ipk" \
	"$VERIFY_ROOT/out/aarch64_generic/24.10.8/usrmanage/"
ROOT="$VERIFY_ROOT"
SDK_MATRIX_VERSION=24.10
SDK_MATRIX_VERSION_LABEL=24.10.8
SDK_MATRIX_PACKAGE_ARCH=x86_64
_x86_before="$(artifact_shas 24.10.8)"
SDK_MATRIX_PACKAGE_ARCH=aarch64_generic
_arm_before="$(artifact_shas 24.10.8)"
make_ipk_fixture usrmanage "$_expected_usr" all "$TMP/arm-changed.ipk" changed-arm-payload
cp "$TMP/arm-changed.ipk" "$VERIFY_ROOT/out/aarch64_generic/24.10.8/usrmanage/usrmanage_${_expected_usr}_all.ipk"
_arm_after="$(artifact_shas 24.10.8)"
SDK_MATRIX_PACKAGE_ARCH=x86_64
_x86_after="$(artifact_shas 24.10.8)"
[[ "$_arm_before" != "$_arm_after" && "$_x86_before" == "$_x86_after" ]] \
	&& ok "repro hashes the selected ARM output, not cached x86" \
	|| bad "repro architecture selection is incorrect"

# The verifier reads these globals after calling this test override.
# shellcheck disable=SC2034
sdk_matrix_resolve() {
	SDK_MATRIX_TARGET="$1"
	SDK_MATRIX_VERSION="$2"
	SDK_MATRIX_VERSION_LABEL=24.10.8
	case "$1" in
		armsr-armv8) SDK_MATRIX_PACKAGE_ARCH=aarch64_generic ;;
		*) SDK_MATRIX_PACKAGE_ARCH=x86_64 ;;
	esac
}
sdk_matrix_source_date_epoch() { printf '1700000000'; }
sdk_matrix_feeds_ready() { [[ "${VERIFY_FEEDS_READY:-1}" == 1 ]]; }
VERIFY_FAIL=
VERIFY_MAKE_COUNT=0
VERIFY_COPY_COUNT=0
sdk_matrix_make() {
	VERIFY_MAKE_COUNT=$((VERIFY_MAKE_COUNT + 1))
	case "$VERIFY_FAIL:$VERIFY_MAKE_COUNT" in make1:1|make2:2) return 42 ;; esac
	return 0
}
sdk_matrix_clean_package() { [[ "$VERIFY_FAIL" != clean ]]; }
sdk_matrix_copy_out() {
	VERIFY_COPY_COUNT=$((VERIFY_COPY_COUNT + 1))
	case "$VERIFY_FAIL:$VERIFY_COPY_COUNT" in copy1:1|copy2:2) return 43 ;; esac
	return 0
}
run_verify_failure() {
	VERIFY_FAIL="$1"
	VERIFY_MAKE_COUNT=0
	VERIFY_COPY_COUNT=0
	if verify_one 24.10 >/dev/null 2>&1; then
		bad "repro verifier accepted injected $1 failure"
	else
		ok "repro verifier propagates injected $1 failure"
	fi
}
run_verify_failure make1
run_verify_failure copy1
run_verify_failure clean
run_verify_failure make2
run_verify_failure copy2
cat > "$VERIFY_ROOT/scripts/docker-sdk.sh" <<'FAILSDK'
#!/bin/sh
exit 41
FAILSDK
chmod +x "$VERIFY_ROOT/scripts/docker-sdk.sh"
VERIFY_FEEDS_READY=0 VERIFY_FAIL=setup
if verify_one 24.10 >/dev/null 2>&1; then
	bad "repro verifier accepted failed initial SDK build"
else
	ok "repro verifier propagates failed initial SDK build"
fi
unset VERIFY_FEEDS_READY
# Restore SDK helpers and repo state for the existing digest/feed tests below.
eval "$_sdk_resolve_original"
eval "$_feeds_ready_original"
eval "$_make_original"
eval "$_clean_original"
eval "$_copy_original"
eval "$_epoch_original"
# The verifier re-sources sdk-matrix.sh; restore the host fixture boundary.
sdk_matrix_read_apk_metadata() { cat "${1}.metadata.json"; }
ROOT="$_repo_root"
unset TARGET VERSIONS
export SDK_MATRIX_DIGEST_CACHE_DIR="$TMP/sdk-digests"
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"

declare -A MOCK_ABSENT=()
declare -A MOCK_REPO=()
declare -A MOCK_ID=()
MOCK_PULL_FAIL=0

docker() {
	local img
	case "$1" in
		pull)
			[[ "$MOCK_PULL_FAIL" != 1 ]] || return 1
			[[ -n "${MOCK_PULL_LOG:-}" ]] && echo "pull $2" >> "$MOCK_PULL_LOG"
			MOCK_ABSENT["$2"]=0
			return 0
			;;
		image)
			[[ "$2" == "inspect" ]] || return 0
			img="${!#}"
			[[ "${MOCK_ABSENT[$img]:-0}" != 1 ]] || return 1
			if [[ -n "${MOCK_REPO[$img]:-}" ]]; then
				printf '%s\n' "${MOCK_REPO[$img]}"
			elif [[ -n "${MOCK_ID[$img]:-}" ]]; then
				printf '%s' "${MOCK_ID[$img]}"
			fi
			return 0
			;;
		*) return 0 ;;
	esac
}

img_ref() { printf 'ghcr.io/openwrt/sdk:%s' "$(sdk_matrix_image_tag "$1" "$2")"; }

# --- 4-cell resolution: literal repo-prefix match (decoy entry listed FIRST, so
#     RepoDigests[0] ordering is explicitly not trusted) ---
declare -A EXPECT=(
	["armsr-armv8/25.12"]="ghcr.io/openwrt/sdk@sha256:aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
	["armsr-armv8/24.10"]="ghcr.io/openwrt/sdk@sha256:bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222"
	["x86-64/25.12"]="ghcr.io/openwrt/sdk@sha256:cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333"
	["x86-64/24.10"]="ghcr.io/openwrt/sdk@sha256:dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444dddd4444"
)
for key in "${!EXPECT[@]}"; do
	target="${key%%/*}"
	version="${key##*/}"
	MOCK_REPO["$(img_ref "$target" "$version")"]="registry.example.net/sdk@sha256:decoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydeco
${EXPECT[$key]}"
done

cells=0
# These arrays are initialized by the sourced matrix helper and stay in the
# current shell; earlier verifier tests mutate their state only in subshells.
# shellcheck disable=SC2031,SC2153
for t in "${SDK_MATRIX_TARGETS[@]}"; do
	# shellcheck disable=SC2031,SC2153
	for v in "${SDK_MATRIX_VERSIONS[@]}"; do
		got="$(sdk_matrix_image_digest "$t" "$v")"
		want="${EXPECT["$t/$v"]}"
		if [[ "$got" == "$want" ]]; then
			ok "digest ${t}/${v}: ${got}"
		else
			bad "digest ${t}/${v}: got '${got}' want '${want}'"
		fi
		cells=$((cells + 1))
	done
done
[[ "$cells" -eq 4 ]] && ok "resolved 4 matrix cells" || bad "resolved $cells cells (want 4)"

# Clear pins so later cases exercise pull / fallback paths (R4 cache).
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"

# --- pin file: digest returned without a second pull ---
pin_img="$(img_ref x86-64 24.10)"
MOCK_REPO["$pin_img"]="${EXPECT[x86-64/24.10]}"
MOCK_ABSENT["$pin_img"]=0
MOCK_PULL_LOG="$TMP/pull-pin.log"
: > "$MOCK_PULL_LOG"
sdk_matrix_pull_and_pin x86-64 24.10 >/dev/null
pulls1="$(wc -l < "$MOCK_PULL_LOG" | tr -d ' ')"
got="$(sdk_matrix_image_digest x86-64 24.10)"
pulls2="$(wc -l < "$MOCK_PULL_LOG" | tr -d ' ')"
[[ "$got" == "${EXPECT[x86-64/24.10]}" && "$pulls1" == "1" && "$pulls2" == "1" ]] \
	&& ok "R4 pin cache avoids re-pull" \
	|| bad "R4 pin cache: got=$got pulls=$pulls1/$pulls2"
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
unset MOCK_PULL_LOG

# --- fallback: empty RepoDigests → @sha256:<image id> + WARNING ---
fallback_img="$(img_ref x86-64 24.10)"
MOCK_REPO["$fallback_img"]=""
MOCK_ID["$fallback_img"]="sha256:feedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed"
MOCK_ABSENT["$fallback_img"]=0
warn="$TMP/fallback-warn.txt"
got="$(sdk_matrix_image_digest x86-64 24.10 2>"$warn")"
if [[ "$got" == "@sha256:feedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeedfeed" ]]; then
	ok "fallback digest uses image id"
else
	bad "fallback digest: got '$got'"
fi
grep -q 'WARNING' "$warn" && ok "fallback emitted WARNING" || bad "no WARNING for fallback"

# --- abort: pull fails (no source) → non-zero, never silent ---
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
MOCK_ABSENT["$(img_ref armsr-armv8 25.12)"]=1
MOCK_PULL_FAIL=1
if sdk_matrix_image_digest armsr-armv8 25.12 >/dev/null 2>&1; then
	bad "digest should abort when pull fails"
else
	ok "digest aborts when pull fails"
fi
MOCK_PULL_FAIL=0

# --- abort: image present but no RepoDigests / id resolvable → non-zero ---
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
MOCK_ABSENT["$(img_ref armsr-armv8 25.12)"]=0
MOCK_REPO["$(img_ref armsr-armv8 25.12)"]=""
MOCK_ID["$(img_ref armsr-armv8 25.12)"]=""
if sdk_matrix_image_digest armsr-armv8 25.12 >/dev/null 2>&1; then
	bad "digest should abort with no resolvable source"
else
	ok "digest aborts with no resolvable source"
fi

# --- manifest records all 4 cell digests (+ packages array intact) ---
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
MOCK_ID=()
for key in "${!EXPECT[@]}"; do
	target="${key%%/*}"
	version="${key##*/}"
	MOCK_REPO["$(img_ref "$target" "$version")"]="registry.example.net/sdk@sha256:decoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydecoydeco
${EXPECT[$key]}"
	MOCK_ABSENT["$(img_ref "$target" "$version")"]=0
done
_feed_root="$TMP/feed-root"
mkdir -p "$_feed_root/out/x86_64/24.10.8/usrmanage" "$_feed_root/out/x86_64/25.12.5/usrmanage"
make_ipk_fixture usrmanage "$_expected_usr" all "$_ipk_dir/usrmanage_${_expected_usr}_all.ipk"
make_ipk_fixture luci-app-usrmanage "$_expected_luci" all "$_ipk_dir/luci-app-usrmanage_${_expected_luci}_all.ipk"
make_apk_fixture usrmanage "$_expected_usr" noarch "$_apk_dir/usrmanage-${_expected_usr}.apk"
make_apk_fixture luci-app-usrmanage "$_expected_luci" noarch "$_apk_dir/luci-app-usrmanage-${_expected_luci}.apk"
cp "$_ipk_dir"/*.ipk "$_feed_root/out/x86_64/24.10.8/usrmanage/"
cp "$_apk_dir"/*.apk "$_feed_root/out/x86_64/25.12.5/usrmanage/"
cp "$_apk_dir"/*.apk.metadata.json "$_feed_root/out/x86_64/25.12.5/usrmanage/"
export FEED_PUBLISH_ROOT="$_feed_root"
_release_stage="$TMP/release-assets"
feed_publish_stage_release_assets "$_release_stage"
_release_names="$(for path in "$_release_stage"/*; do [ -f "$path" ] || continue; basename "$path"; done | sort)"
_release_count="$(printf '%s\n' "$_release_names" | grep -c .)"
[[ "$_release_count" -eq 4 ]] && ok "release staging has both packages for both versions" || bad "release asset count=$_release_count"
feed_publish_release_asset_names_match "$_release_stage" "$_release_names" \
	&& ok "immutable release exact asset-name set matches" \
	|| bad "immutable release exact asset-name comparison failed"
_partial_names="$(printf '%s\n' "$_release_names" | head -3)"
if feed_publish_release_asset_names_match "$_release_stage" "$_partial_names"; then
	bad "partial immutable release asset set was accepted"
else
	ok "partial immutable release asset set rejected"
fi
rm -f "$_feed_root/out/x86_64/25.12.5/usrmanage/luci-app-usrmanage-${_expected_luci}.apk"
if feed_publish_stage_release_assets "$TMP/release-missing" >/dev/null 2>&1; then
	bad "release staging accepted missing package cell"
else
	[ ! -e "$TMP/release-missing" ] && ok "release staging fails before creating partial assets" \
		|| bad "release staging created partial assets before validation"
fi
make_apk_fixture luci-app-usrmanage "$_expected_luci" noarch "$_feed_root/out/x86_64/25.12.5/usrmanage/luci-app-usrmanage-${_expected_luci}.apk"
stage="$TMP/stage"
mkdir -p "$stage"
feed_publish_write_manifest "$stage" "v0.1.9"
[[ -f "$stage/manifest.json" ]] || { bad "manifest.json not written"; exit 1; }
n="$(jq '.sdk_images | length' "$stage/manifest.json")"
[[ "$n" -eq 4 ]] && ok "manifest has 4 sdk_images" || bad "manifest sdk_images length $n (want 4)"
allok=1
for key in "${!EXPECT[@]}"; do
	target="${key%%/*}"
	version="${key##*/}"
	label="$(sdk_matrix_version_label "$version")"
	got="$(jq -r --arg v "$label" --arg t "$target" '.sdk_images[] | select(.openwrt==$v and .target==$t) | .digest' "$stage/manifest.json")"
	[[ "$got" == "${EXPECT[$key]}" ]] || { bad "manifest digest ${target}/${version}: $got"; allok=0; }
done
[[ "$allok" -eq 1 ]] && ok "manifest digests match all 4 cells"
jq -e '.packages | type == "array" and length == 4' "$stage/manifest.json" >/dev/null \
	&& ok "manifest contains all four required package artifacts" || bad "manifest package set missing/partial"

# --- manifest aborts (non-zero) when a cell digest cannot be resolved ---
rm -rf "${SDK_MATRIX_DIGEST_CACHE_DIR:?}"/*
mkdir -p "$SDK_MATRIX_DIGEST_CACHE_DIR"
mkdir -p "$TMP/badstage"
MOCK_ABSENT["$(img_ref x86-64 25.12)"]=1
MOCK_PULL_FAIL=1
if feed_publish_write_manifest "$TMP/badstage" "v0.1.9" >/dev/null 2>&1; then
	bad "manifest should fail when a cell digest is unresolvable"
else
	ok "manifest fails fast when a cell digest is unresolvable"
fi
MOCK_PULL_FAIL=0

# --- ipkg index cache TOCTOU (luna r2 fold): symlinked seed must NOT come
# back as an executable symlink --------------------------------------------
# Genuine discriminator: the attacker symlinks the seed at the LEGITIMATE
# file (so a source-hash check — which follows symlinks — MATCHES). Pre-fold
# `cp -a` copies the LINK itself, so the returned $tmp is a symlink to the
# attacker-chosen path (re-pointable after the check). The fix `cp -aL`
# dereferences and writes the target's CONTENT into the fresh private
# regular file. Assert: returned file is a REGULAR file with the legit hash.
cache_dir="$TMP/ipkg-cache"
mkdir -p "$cache_dir"
export FEED_PUBLISH_IPKG_INDEX_CACHE="$cache_dir"
# fetch the REAL upstream script once, save to a stable file (curl -o keeps
# the exact bytes incl. trailing newline — do NOT use $(...) which strips).
real_file="$TMP/real-ipkg-make-index.sh"
if curl -fsSL 'https://raw.githubusercontent.com/openwrt/openwrt/0b795ce79e23b553aa184080c390f9ce92a2b6d4/scripts/ipkg-make-index.sh' -o "$real_file" 2>/dev/null && [[ -s "$real_file" ]]; then
	exp="$(sha256sum "$real_file" | awk '{print $1}')"
	# attacker: seed name -> symlink to the LEGIT file (hash checks pass)
	ln -sf "$real_file" "$cache_dir/ipkg-make-index-24.10.8.sh"
	got_file="$(feed_publish_ipkg_index_script 24.10.8)"
	got_sum="$(sha256sum "$got_file" | awk '{print $1}')"
	if [[ "$got_sum" == "$exp" ]] && [[ -f "$got_file" && ! -L "$got_file" ]]; then
		ok "ipkg cache TOCTOU: symlinked seed returned as REGULAR file (cp -aL)"
	else
		bad "ipkg cache TOCTOU: not a regular file or hash=$got_sum"
	fi
	rm -f "$got_file"
else
	bad "ipkg cache TOCTOU test: upstream fetch unavailable"
	exit 1   # controlled diagnostic — do NOT fall through to cp (luna r4)
fi

# --- ipkg cache valid-hit path: no refetch, verified copy ------------------
# Seed = the exact downloaded bytes. A working cache must return the
# verified copy WITHOUT calling curl again. A curl mock (named `curl`, on a
# PATH-prefixed bin dir) records calls; if the seed were treated as invalid
# the function would refetch and the mock would record it.
mkdir -p "$TMP/bin"
REAL_CURL="$(command -v curl)"
cat > "$TMP/bin/curl" <<CURL
#!/bin/sh
# Mock: record the call AND write real bytes (so a refetch path completes
# and the test can assert refetch_count; a silent mock would exit the test
# under set -e before the assertion runs — luna r3 fold).
echo "CURL-CALLED" >> "\$MOCK_CURL_LOG"
exec "$REAL_CURL" "\$@" </dev/null 2>/dev/null || true
CURL
chmod +x "$TMP/bin/curl"
export MOCK_CURL_LOG="$TMP/curl.log"
: > "$MOCK_CURL_LOG"
rm -f "$cache_dir/ipkg-make-index-24.10.8.sh"   # drop the TOCTOU symlink
cp "$real_file" "$cache_dir/ipkg-make-index-24.10.8.sh"
# PATH is scoped only to this command; it must not persist in the test shell.
# shellcheck disable=SC2031
got_file="$(PATH="$TMP/bin:$PATH" MOCK_CURL_LOG="$MOCK_CURL_LOG" feed_publish_ipkg_index_script 24.10.8)"
got_sum="$(sha256sum "$got_file" | awk '{print $1}')"
refetch_count="$(wc -l < "$MOCK_CURL_LOG" 2>/dev/null | tr -d ' ')"
if [[ "$got_sum" == "$exp" ]] && [[ "$refetch_count" == "0" ]]; then
	ok "ipkg cache valid seed: verified copy, no refetch"
else
	bad "ipkg cache valid seed: hash=$got_sum refetches=$refetch_count"
fi
rm -f "$got_file"
unset MOCK_CURL_LOG

# --- sdk_matrix_pull must re-resolve tags (luna fold): pull always ----------
# Pre-fold, an image present locally (MOCK_ABSENT=0) skipped pull; a stale
# local tag then recorded a stale digest. Fixed code always pulls. The mock
# records pulls; assert the pull count for a present image is > 0.
MOCK_PULL_LOG="$TMP/pulls.log"
: > "$MOCK_PULL_LOG"
img_present="$(img_ref x86-64 24.10)"
MOCK_ABSENT["$img_present"]=0   # image exists locally
sdk_matrix_pull x86-64 24.10
pulls="$(grep -c "$img_present" "$MOCK_PULL_LOG" || true)"
if [[ "$pulls" -ge 1 ]]; then
	ok "sdk_matrix_pull always re-resolves (pull fired on present image)"
else
	bad "sdk_matrix_pull skipped pull on present image (stale digest risk)"
fi
unset MOCK_PULL_LOG

[ "$fail" = "0" ] || exit 1
echo "ALL TESTS PASSED"
