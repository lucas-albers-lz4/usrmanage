#!/usr/bin/env bash
# Shared helpers for staging signed opkg/apk feeds.
# Source from publish-packages.sh — do not execute directly.
set -euo pipefail

# shellcheck source=sdk-matrix.sh
source "$(dirname "${BASH_SOURCE[0]}")/sdk-matrix.sh"

feed_publish_root() {
	if [[ -n "${FEED_PUBLISH_ROOT:-}" ]]; then
		printf '%s' "$FEED_PUBLISH_ROOT"
		return 0
	fi
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	printf '%s' "$here"
}

feed_publish_abspath() {
	local path="$1"
	if [[ "$path" != /* ]]; then
		path="$(feed_publish_root)/${path#./}"
	fi
	(
		cd "$(dirname "$path")"
		printf '%s/%s' "$(pwd)" "$(basename "$path")"
	)
}

# Map user version key → feed directory name on GitHub Pages.
feed_publish_feed_dir() {
	case "$(sdk_matrix_version_label "$1")" in
		21.02.7) printf '%s' '21.02' ;;
		22.03.7) printf '%s' '22.03' ;;
		24.10.8) printf '%s' '24.10' ;;
		25.12.5) printf '%s' '25.12' ;;
		*) sdk_matrix_version_label "$1" ;;
	esac
}

feed_publish_find_artifacts() {
	# Print all usrmanage + luci-app-usrmanage artifacts for a version label (one per line).
	local version_label="$1"
	local root dir
	root="$(feed_publish_root)"
	dir="${root}/out/x86_64/${version_label}/usrmanage"
	shopt -s nullglob
	local candidates=(
		"${dir}"/usrmanage_*_all.ipk
		"${dir}"/luci-app-usrmanage_*_all.ipk
		"${dir}"/usrmanage-*.apk
		"${dir}"/luci-app-usrmanage-*.apk
		"${dir}"/usrmanage_*.apk
		"${dir}"/luci-app-usrmanage_*.apk
	)
	shopt -u nullglob
	[[ ${#candidates[@]} -ge 1 ]] || return 1
	printf '%s\n' "${candidates[@]}" | sort -u
}

# Back-compat: first artifact (prefer luci-app for single-file callers)
feed_publish_find_artifact() {
	feed_publish_find_artifacts "$1" | head -1
}

# Map SDK output dir (e.g. 21.02.7) → feed/release key (e.g. 21.02).
feed_publish_release_key() {
	case "$1" in
		21.02.7) printf '%s' '21.02' ;;
		22.03.7) printf '%s' '22.03' ;;
		24.10.8) printf '%s' '24.10' ;;
		25.12.5) printf '%s' '25.12' ;;
		*) printf '%s' "$1" ;;
	esac
}

# GitHub Releases require unique asset basenames; each OpenWrt line builds the same _all.ipk name.
feed_publish_release_asset_basename() {
	local path="$1"
	local ver_label base key
	ver_label="$(basename "$(dirname "$(dirname "$path")")")"
	base="$(basename "$path")"
	key="$(feed_publish_release_key "$ver_label")"
	if [[ "$base" == *.ipk ]]; then
		printf '%s' "${base/_all.ipk/_${key}_all.ipk}"
	else
		printf '%s' "$base"
	fi
}

# Copy built artifacts into a flat dir with unique release asset names.
feed_publish_stage_release_assets() {
	local dest="$1"
	local ver ver_label path name
	mkdir -p "$dest"
	find "$dest" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
	for ver in 24.10 25.12; do
		ver_label="$(sdk_matrix_version_label "$ver")"
		while IFS= read -r path; do
			[[ -n "$path" ]] || continue
			name="$(feed_publish_release_asset_basename "$path")"
			if [[ -e "${dest}/${name}" ]]; then
				echo "duplicate release asset name: ${name} (${path})" >&2
				return 1
			fi
			cp -a "$path" "${dest}/${name}"
		done < <(feed_publish_find_artifacts "$ver_label" 2>/dev/null || true)
	done
}

# Pinned usign revision for host-side opkg feed signing (no fixed /tmp path; fresh build per call).
# Resolved via: git ls-remote https://github.com/openwrt/usign master
USIGN_PIN_SHA='c4c72b1b07945ee192361dc751291a7c98d6adcd'

feed_publish_ensure_usign() {
	if command -v usign >/dev/null 2>&1; then
		return 0
	fi
	local build_dir rc
	command -v cmake >/dev/null 2>&1 || {
		echo "usign build needs cmake (pinned ${USIGN_PIN_SHA}); install cmake or put usign on PATH" >&2
		return 1
	}
	build_dir="$(mktemp -d "${TMPDIR:-/tmp}/usrmanage-usign-build.XXXXXX")" || return 1
	echo "→ building pinned usign (${USIGN_PIN_SHA}) in ${build_dir}..." >&2
	rc=0
	(
		set -e
		git init -q "${build_dir}/src"
		git -C "${build_dir}/src" remote add origin "https://github.com/openwrt/usign.git"
		git -C "${build_dir}/src" fetch -q --depth 1 origin "${USIGN_PIN_SHA}"
		git -C "${build_dir}/src" checkout -q "${USIGN_PIN_SHA}"
		cmake -S "${build_dir}/src" -B "${build_dir}/build" >/dev/null
		make -C "${build_dir}/build" -j"$(nproc 2>/dev/null || echo 2)" >/dev/null
		ln -sf "${build_dir}/build/usign" "${build_dir}/usign"
	) || rc=1
	if [[ "$rc" -ne 0 ]]; then
		rm -rf "$build_dir"
		echo "usign build failed (pinned ${USIGN_PIN_SHA})" >&2
		return 1
	fi
	export PATH="${build_dir}:${PATH}"
	command -v usign >/dev/null
}

feed_publish_ipkg_index_script() {
	# Fetch ipkg-make-index.sh pinned to a commit SHA and verify its sha256 AFTER fetch,
	# BEFORE it can execute. A fixed-path cache is used only as a RE-VERIFIED read-only seed;
	# the returned path is a fresh private mktemp file (caller-owned cleanup, trap RETURN).
	local ver_label="$1"
	local cache ref sha_expected tmp actual seed
	cache="${FEED_PUBLISH_IPKG_INDEX_CACHE:-/tmp/usrmanage-ipkg-make-index}"
	case "$ver_label" in
		24.10.8)
			ref='0b795ce79e23b553aa184080c390f9ce92a2b6d4' # tag v24.10.8
			sha_expected='f19c5013c38d2dc54a95457dd372cb4b6a077ca6ddf7ef3da982b7b6e49b6d06'
			;;
		25.12.5)
			ref='f0a60eee2fe051741c643ea6118718aae1ef17fb' # tag v25.12.5
			sha_expected='f19c5013c38d2dc54a95457dd372cb4b6a077ca6ddf7ef3da982b7b6e49b6d06'
			;;
		*)
			echo "ipkg-make-index: unsupported version label: ${ver_label} (24.10.8 / 25.12.5 only)" >&2
			return 1
			;;
	esac
	tmp="$(mktemp)"
	seed="${cache}/ipkg-make-index-${ver_label}.sh"
	if [[ -f "$seed" ]]; then
		# TOCTOU-closed (luna fold 2026-08-10): hash the COPY, not the
		# cache — a writable cache or symlink can be swapped between the
		# source hash and the cp. `cp -aL` DEREFERENCES a symlink seed and
		# writes the target's CONTENT into the fresh private $tmp regular
		# file (a bare `cp -a` would copy the link itself, making $tmp a
		# symlink the refetch could then follow into attacker-chosen
		# paths). Verify the copy's hash: mismatch => refetch.
		cp -aL "$seed" "$tmp"
		actual="$(sha256sum "$tmp" | awk '{print $1}')"
		if [[ "$actual" == "$sha_expected" ]]; then
			chmod +x "$tmp"
			printf '%s' "$tmp"
			return 0
		fi
		echo "ipkg-make-index: cache ${seed} failed re-verification (got ${actual}); refetching pinned ${ref}" >&2
	fi
	if ! curl -fsSL "https://raw.githubusercontent.com/openwrt/openwrt/${ref}/scripts/ipkg-make-index.sh" -o "$tmp"; then
		rm -f "$tmp"
		echo "ipkg-make-index: fetch failed (pinned ${ref})" >&2
		return 1
	fi
	actual="$(sha256sum "$tmp" | awk '{print $1}')"
	if [[ "$actual" != "$sha_expected" ]]; then
		rm -f "$tmp"
		echo "ipkg-make-index: sha256 mismatch for pinned ${ref} (got ${actual}, want ${sha_expected}); refusing to execute" >&2
		return 1
	fi
	chmod +x "$tmp"
	printf '%s' "$tmp"
}

feed_publish_stage_opkg_host() {
	local pkg_dir="$1" ver_label="$2"
	local index_script raw mkhash
	index_script="$(feed_publish_ipkg_index_script "$ver_label")"
	raw="$(mktemp)"
	trap 'rm -f "$index_script" "$raw"' RETURN
	# ipkg-make-index.sh uses $MKHASH sha256 (OpenWrt mkhash), not sha256sum alone.
	mkhash=""
	for ver in 25.12 24.10; do
		sdk_matrix_resolve x86-64 "$ver" 2>/dev/null || continue
		if sdk_matrix_feeds_ready 2>/dev/null; then
			mkhash="$(sdk_matrix_compose_run sh -c 'test -x /builder/staging_dir/host/bin/mkhash && echo /builder/staging_dir/host/bin/mkhash' 2>/dev/null | tr -d '\r' || true)"
			[[ -n "$mkhash" ]] && break
		fi
	done
	[[ -n "$mkhash" ]] || mkhash="$(command -v mkhash || true)"
	if ! ( cd "$pkg_dir" && MKHASH="${mkhash:-mkhash}" "$index_script" . >"$raw" ); then
		echo "ipkg-make-index failed for ${ver_label}" >&2
		cat "$raw" >&2
		rm -f "$raw"
		return 1
	fi
	grep -vE '^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)' "$raw" > "${pkg_dir}/Packages" || true
	rm -f "$raw"
	[[ -s "${pkg_dir}/Packages" ]] || {
		echo "empty Packages index for ${ver_label}" >&2
		return 1
	}
	gzip -9cn "${pkg_dir}/Packages" > "${pkg_dir}/Packages.gz"
	feed_publish_ensure_usign || {
		echo "usign not available (install or run after docker-sdk build)" >&2
		return 1
	}
	usign -S -m "${pkg_dir}/Packages" -s "$OPKG_FEED_SECRET_KEY" -x "${pkg_dir}/Packages.sig"
}

feed_publish_stage_opkg_sdk() {
	local version_key="$1" pkg_dir="$2"
	local root key_abs tools_dir
	root="$(feed_publish_root)"
	pkg_dir="$(feed_publish_abspath "$pkg_dir")"
	key_abs="$(feed_publish_abspath "$OPKG_FEED_SECRET_KEY")"
	sdk_matrix_resolve x86-64 "$version_key"
	# Prefer digest-pinned image from build-time cache when present (R4).
	if _pin="$(sdk_matrix_read_digest_cache x86-64 "$version_key")"; then
		SDK_MATRIX_IMAGE="$_pin"
	fi
	sdk_matrix_feeds_ready \
		|| { echo "run docker-sdk.sh build --version ${version_key} before staging opkg feed" >&2; return 1; }
	# R2: copy signing tools out of the shared /builder volume before mounting secrets.
	# The SDK's usign/mkhash/apk are runas wrapper scripts: `bin/<tool>` execs
	# `../lib/ld-linux-x86-64.so.2` with LD_PRELOAD=runas.so against the hidden
	# real binary `bin/.<tool>.bin`. Export the wrapper into /feed/tools AND the
	# shared-lib tree into /feed/lib (a sibling mount) so the wrapper's ../lib
	# resolution survives outside /builder.
	#
	# Export uses the dedicated `sdk-export` compose service (SDK volume only,
	# NO workspace mount) as the invoking uid — the workspace holds the signing
	# keys, so the export container must never see it. Only world-readable
	# *.so* libs are copied (the 0600 buildbot-owned meson/ templates are not
	# needed by the runas wrappers), so root is not required.
	tools_dir="$(mktemp -d "${TMPDIR:-/tmp}/um-sign-tools.XXXXXX")"
	lib_dir="$(mktemp -d "${TMPDIR:-/tmp}/um-sign-lib.XXXXXX")"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm --user "$(id -u):$(id -g)" \
			-v "${tools_dir}:/feed/tools" \
			-v "${lib_dir}:/feed/lib" \
			sdk-export sh -ec '
				set -e
				cp -a /builder/staging_dir/host/bin/usign /feed/tools/usign
				cp -a /builder/staging_dir/host/bin/.usign.bin /feed/tools/.usign.bin
				cp -a /builder/staging_dir/host/bin/mkhash /feed/tools/mkhash
				cp -a /builder/staging_dir/host/bin/.mkhash.bin /feed/tools/.mkhash.bin
				cp -a /builder/scripts/ipkg-make-index.sh /feed/tools/ipkg-make-index.sh
				cp -a /builder/staging_dir/host/lib/*.so* /feed/lib/
				chmod a+x /feed/tools/usign /feed/tools/.usign.bin /feed/tools/mkhash /feed/tools/.mkhash.bin /feed/tools/ipkg-make-index.sh
			'
	) || {
		rm -rf "$tools_dir" "$lib_dir"
		echo "failed to export opkg signing tools from SDK volume" >&2
		return 1
	}
	(
		cd "$root"
		# Compose v2 `run` has no --network; use docker run --network none with
		# the digest-pinned image and exported tools only (no /builder mount).
		# Tools mount at /feed/tools and libs at /feed/lib (siblings) so the
		# runas wrapper's ../lib resolution works; pkgdir stays a plain mount.
		# Guard with `if` so a failed sign still cleans up the temp dirs
		# (the script runs under `set -e`).
		if docker run --rm --network none --user root --platform linux/amd64 \
			-v "${pkg_dir}:/feed/pkgdir" \
			-v "${key_abs}:/feed/opkg-secret.key:ro" \
			-v "${tools_dir}:/feed/tools:ro" \
			-v "${lib_dir}:/feed/lib:ro" \
			"$SDK_MATRIX_IMAGE" \
			sh -ec '
				set -e
				USIGN=/feed/tools/usign
				INDEX=/feed/tools/ipkg-make-index.sh
				MKHASH=/feed/tools/mkhash
				export PATH="/feed/tools:$PATH"
				export MKHASH
				test -x "$USIGN"
				test -x "$INDEX"
				test -x "$MKHASH"
				cd /feed/pkgdir
				RAW="$(mktemp)"
				"$INDEX" . >"$RAW"
				grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" "$RAW" > Packages || true
				rm -f "$RAW"
				test -s Packages
				gzip -9cn Packages > Packages.gz
				if ! "$USIGN" -S -m Packages -s /feed/opkg-secret.key -x Packages.sig; then
					echo "usign failed: OPKG_FEED_SECRET_KEY must be the full usign secret from:" >&2
					echo "  usign -G -s opkg-secret.key -p public.key -c \"usrmanage opkg feed\"" >&2
					echo "(not the apk RSA key; include both comment and base64 lines)" >&2
					exit 1
				fi
			'
		then
			rc=0
		else
			rc=$?
		fi
		exit "$rc"
	)
	local rc=$?
	rm -rf "$tools_dir" "$lib_dir"
	return "$rc"
}

feed_publish_stage_opkg() {
	local version_key="$1" staging="$2"
	local ver_label feed_dir artifact pkg_dir count=0
	ver_label="$(sdk_matrix_version_label "$version_key")"
	feed_dir="${staging}/$(feed_publish_feed_dir "$version_key")"
	mkdir -p "$feed_dir"
	while IFS= read -r artifact; do
		[[ -n "$artifact" ]] || continue
		cp -a "$artifact" "$feed_dir/"
		count=$((count + 1))
	done < <(feed_publish_find_artifacts "$ver_label" 2>/dev/null || true)
	[[ "$count" -ge 1 ]] || {
		echo "missing built ipk for ${ver_label} under out/x86_64/${ver_label}/usrmanage/" >&2
		return 1
	}
	[[ -n "${OPKG_FEED_SECRET_KEY:-}" ]] || {
		echo "OPKG_FEED_SECRET_KEY must point to usign secret key file" >&2
		return 1
	}
	pkg_dir="$feed_dir"
	sdk_matrix_resolve x86-64 "$version_key"
	if sdk_matrix_feeds_ready 2>/dev/null; then
		echo "  index+sign via SDK (${SDK_MATRIX_IMAGE})" >&2
		feed_publish_stage_opkg_sdk "$version_key" "$pkg_dir"
	else
		echo "  index+sign on host (no SDK volume)" >&2
		feed_publish_stage_opkg_host "$pkg_dir" "$ver_label"
	fi
}

feed_publish_stage_apk() {
	local version_key="$1" staging="$2"
	local ver_label feed_dir artifact pkg_dir count=0
	ver_label="$(sdk_matrix_version_label "$version_key")"
	feed_dir="${staging}/$(feed_publish_feed_dir "$version_key")/all"
	mkdir -p "$feed_dir"
	while IFS= read -r artifact; do
		[[ -n "$artifact" ]] || continue
		cp -a "$artifact" "$feed_dir/"
		count=$((count + 1))
	done < <(feed_publish_find_artifacts "$ver_label" 2>/dev/null || true)
	[[ "$count" -ge 1 ]] || {
		echo "missing built apk for ${ver_label} under out/x86_64/${ver_label}/usrmanage/" >&2
		return 1
	}
	[[ -n "${APK_FEED_SECRET_KEY:-}" ]] || {
		echo "APK_FEED_SECRET_KEY must point to RSA private key for apk mkndx --sign" >&2
		return 1
	}
	pkg_dir="$feed_dir"
	sdk_matrix_resolve x86-64 "$version_key"
	if _pin="$(sdk_matrix_read_digest_cache x86-64 "$version_key")"; then
		SDK_MATRIX_IMAGE="$_pin"
	fi
	sdk_matrix_feeds_ready \
		|| { echo "run docker-sdk.sh build --version ${version_key} before staging apk feed" >&2; return 1; }
	local root key_abs tools_dir lib_dir
	root="$(feed_publish_root)"
	pkg_dir="$(feed_publish_abspath "$pkg_dir")"
	key_abs="$(feed_publish_abspath "$APK_FEED_SECRET_KEY")"
	# R2: export apk from /builder before mounting the signing secret.
	# bin/apk is a runas wrapper script: exports `../lib/ld-linux-x86-64.so.2`
	# with LD_PRELOAD=runas.so against the hidden bin/.apk.bin. Export the
	# wrapper into /feed/tools AND the shared-lib tree into /feed/lib (a
	# sibling mount) so ../lib resolution survives. Export uses the dedicated
	# `sdk-export` compose service (SDK volume only, NO workspace mount) as the
	# invoking uid; only world-readable *.so* libs are copied, so root is not
	# required and the signing keys in the workspace are never visible.
	tools_dir="$(mktemp -d "${TMPDIR:-/tmp}/um-sign-tools.XXXXXX")"
	lib_dir="$(mktemp -d "${TMPDIR:-/tmp}/um-sign-lib.XXXXXX")"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm --user "$(id -u):$(id -g)" \
			-v "${tools_dir}:/feed/tools" \
			-v "${lib_dir}:/feed/lib" \
			sdk-export sh -ec '
				set -e
				cp -a /builder/staging_dir/host/bin/apk /feed/tools/apk
				cp -a /builder/staging_dir/host/bin/.apk.bin /feed/tools/.apk.bin
				cp -a /builder/staging_dir/host/lib/*.so* /feed/lib/
				chmod a+x /feed/tools/apk /feed/tools/.apk.bin
			'
	) || {
		rm -rf "$tools_dir" "$lib_dir"
		echo "failed to export apk signing tool from SDK volume" >&2
		return 1
	}
	(
		cd "$root"
		# Compose v2 `run` has no --network; use docker run --network none with
		# the digest-pinned image and exported tools only (no /builder mount).
		# Tools mount at /feed/tools and libs at /feed/lib (siblings) so the
		# runas wrapper's ../lib resolution works; pkgdir stays a plain mount.
		# Guard with `if` so a failed sign still cleans up the temp dirs
		# (the script runs under `set -e`).
		if docker run --rm --network none --user root --platform linux/amd64 \
			-v "${pkg_dir}:/feed/pkgdir" \
			-v "${key_abs}:/feed/apk-secret.rsa:ro" \
			-v "${tools_dir}:/feed/tools:ro" \
			-v "${lib_dir}:/feed/lib:ro" \
			"$SDK_MATRIX_IMAGE" \
			sh -ec '
				set -e
				APK=/feed/tools/apk
				test -x "$APK"
				cd /feed/pkgdir
				"$APK" mkndx --allow-untrusted --sign /feed/apk-secret.rsa --output packages.adb *.apk
			'
		then
			rc=0
		else
			rc=$?
		fi
		exit "$rc"
	)
	local rc=$?
	rm -rf "$tools_dir" "$lib_dir"
	return "$rc"
}

feed_publish_copy_keys() {
	local staging="$1"
	[[ -n "${OPKG_FEED_PUBLIC_KEY:-}" && -f "$OPKG_FEED_PUBLIC_KEY" ]] && cp -a "$OPKG_FEED_PUBLIC_KEY" "${staging}/public.key"
	[[ -n "${APK_FEED_PUBLIC_KEY:-}" && -f "$APK_FEED_PUBLIC_KEY" ]] && cp -a "$APK_FEED_PUBLIC_KEY" "${staging}/usrmanage-feed.rsa.pub"
}

feed_publish_write_manifest() {
	local staging="$1" git_tag="${2:-unknown}"
	local manifest ver artifact ver_label sum
	local target image digest
	manifest="${staging}/manifest.json"
	: > "$manifest"
	printf '{\n  "git_tag": "%s",\n  "sdk_images": [\n' "${git_tag//\"/\\\"}" >> "$manifest"
	local first=1
	for target in "${SDK_MATRIX_TARGETS[@]}"; do
		for ver in "${SDK_MATRIX_VERSIONS[@]}"; do
			digest="$(sdk_matrix_image_digest "$target" "$ver")" || {
				echo "feed-publish: no SDK image digest for ${target}/${ver}" >&2
				return 1
			}
			image="ghcr.io/openwrt/sdk:$(sdk_matrix_image_tag "$target" "$ver")"
			[[ $first -eq 1 ]] || printf ',\n' >> "$manifest"
			first=0
			printf '    {"openwrt": "%s", "target": "%s", "image": "%s", "digest": "%s"}' \
				"$(sdk_matrix_version_label "$ver")" "$target" "$image" "$digest" >> "$manifest"
		done
	done
	printf '\n  ],\n  "packages": [\n' >> "$manifest"
	first=1
	for ver in 24.10 25.12; do
		ver_label="$(sdk_matrix_version_label "$ver")"
		while IFS= read -r artifact; do
			[[ -n "$artifact" ]] || continue
			sum="$(sha256sum "$artifact" | awk '{print $1}')"
			[[ $first -eq 1 ]] || printf ',\n' >> "$manifest"
			first=0
			printf '    {"openwrt": "%s", "file": "%s", "sha256": "%s"}' "$ver" "$(basename "$artifact")" "$sum" >> "$manifest"
		done < <(feed_publish_find_artifacts "$ver_label" 2>/dev/null || true)
	done
	printf '\n  ]\n}\n' >> "$manifest"
}
