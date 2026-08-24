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
if [[ -n "$_build_ln" && -n "$_repro_ln" && -n "$_keys_ln" &&
      "$_keys_ln" -gt "$_build_ln" && "$_keys_ln" -gt "$_repro_ln" ]]; then
	ok "publish workflow: signing keys written after SDK builds + repro gate (#159)"
else
	bad "publish workflow: feed_keys_write_from_env must follow last SDK build and reproducible gate"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
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
for t in "${SDK_MATRIX_TARGETS[@]}"; do
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
jq -e '.packages | type == "array"' "$stage/manifest.json" >/dev/null \
	&& ok "manifest packages array present" || bad "manifest packages array missing"

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
