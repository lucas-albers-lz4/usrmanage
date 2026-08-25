#!/usr/bin/env bash
# OpenWrt SDK build matrix helpers for usrmanage (ghcr.io/openwrt/sdk).
# Source from other scripts; do not execute directly.
set -euo pipefail

SDK_MATRIX_TARGETS=(armsr-armv8 x86-64)
SDK_MATRIX_VERSIONS=(25.12 24.10)

sdk_matrix_root() {
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
	printf '%s' "$here"
}

sdk_matrix_version_patch() {
	case "$1" in
		25.12 | 25.12.*) printf '%s' '25.12.5' ;;
		24.10 | 24.10.*) printf '%s' '24.10.8' ;;
		*) printf '%s' "$1" ;;
	esac
}

sdk_matrix_version_label() {
	sdk_matrix_version_patch "$1"
}

sdk_matrix_image_tag() {
	local target="$1" version="$2" patch
	patch="$(sdk_matrix_version_patch "$version")"
	printf '%s' "${target}-${patch}"
}

sdk_matrix_package_arch() {
	case "$1" in
		armsr-armv8) printf '%s' 'aarch64_generic' ;;
		x86-64) printf '%s' 'x86_64' ;;
		*) echo "unknown SDK target: $1 (expected armsr-armv8 or x86-64)" >&2; return 1 ;;
	esac
}

sdk_matrix_volume_name() {
	local target="$1" version="$2" patch tslug vslug
	patch="$(sdk_matrix_version_patch "$version")"
	tslug="${target//-/_}"
	vslug="${patch//./_}"
	printf '%s' "openwrt_sdk_${tslug}_${vslug}"
}

sdk_matrix_resolve() {
	local target="${1:-x86-64}" version="${2:-24.10}"
	SDK_MATRIX_TARGET="$target"
	SDK_MATRIX_VERSION="$version"
	SDK_MATRIX_VERSION_LABEL="$(sdk_matrix_version_label "$version")"
	SDK_MATRIX_IMAGE="ghcr.io/openwrt/sdk:$(sdk_matrix_image_tag "$target" "$version")"
	SDK_MATRIX_VOLUME="$(sdk_matrix_volume_name "$target" "$version")"
	SDK_MATRIX_PACKAGE_ARCH="$(sdk_matrix_package_arch "$target")"
	SDK_MATRIX_OUT_DIR="$(sdk_matrix_root)/out/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}"
}

sdk_matrix_digest_cache_path() {
	local target="$1" version="$2" patch base
	patch="$(sdk_matrix_version_patch "$version")"
	base="${SDK_MATRIX_DIGEST_CACHE_DIR:-$(sdk_matrix_root)/out/.sdk-digests}"
	printf '%s' "${base}/${target}_${patch}"
}

sdk_matrix_inspect_repo_digest() {
	# Inspect already-local image ref; print matching RepoDigest or fail.
	local image="$1" repo digests digest id
	if [[ "$image" == *@sha256:* ]]; then
		repo="${image%%@*}"
	else
		repo="${image%%:*}"
	fi
	digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" 2>/dev/null || true)"
	digest="$(printf '%s\n' "$digests" | awk -v repo="$repo" 'index($0, repo "@sha256:")==1 {print; exit}')"
	if [[ -n "$digest" ]]; then
		printf '%s' "$digest"
		return 0
	fi
	id="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
	if [[ -n "$id" ]]; then
		echo "sdk-matrix: WARNING ${image} has no RepoDigest; falling back to image id sha256:${id#sha256:}" >&2
		printf '%s' "@sha256:${id#sha256:}"
		return 0
	fi
	echo "sdk-matrix: no resolvable source for ${image} (not pulled / no digest)" >&2
	return 1
}

sdk_matrix_pull() {
	# Ensure the SDK image for a matrix cell is present locally so its digest can be
	# recorded (tags are mutable; always re-resolve against the registry).
	# NOTE (luna fold 2026-08-10): do NOT skip pull when the tag exists
	# locally — a stale local tag would record a digest that no longer
	# matches the registry. docker pull of an unchanged tag is a cheap
	# manifest re-resolution; if the tag moved upstream, the local image
	# (and its RepoDigests) is updated here before the digest is read.
	local target="${1:-x86-64}" version="${2:-24.10}"
	sdk_matrix_resolve "$target" "$version"
	docker pull "$SDK_MATRIX_IMAGE"
}

sdk_matrix_pull_and_pin() {
	# R4: pull the mutable tag once, pin SDK_MATRIX_IMAGE to repo@sha256, cache digest.
	local target="${1:-x86-64}" version="${2:-24.10}" digest cache
	sdk_matrix_pull "$target" "$version" || {
		echo "sdk-matrix: failed to pull ${SDK_MATRIX_IMAGE}" >&2
		return 1
	}
	digest="$(sdk_matrix_inspect_repo_digest "$SDK_MATRIX_IMAGE")" || return 1
	cache="$(sdk_matrix_digest_cache_path "$target" "$version")"
	mkdir -p "$(dirname "$cache")"
	printf '%s\n' "$digest" > "$cache"
	chmod 0644 "$cache" 2>/dev/null || true
	SDK_MATRIX_IMAGE="$digest"
	printf '%s' "$digest"
}

sdk_matrix_read_digest_cache() {
	# Print non-empty cached digest or return 1 (never print empty).
	local target="$1" version="$2" cache digest
	cache="$(sdk_matrix_digest_cache_path "$target" "$version")"
	[[ -f "$cache" ]] || return 1
	digest="$(tr -d ' \n\r\t' < "$cache")"
	[[ -n "$digest" ]] || return 1
	printf '%s' "$digest"
}

sdk_matrix_image_digest() {
	# Print the resolved digest of the SDK image for a matrix cell (target, version).
	# Prefers a pin file written by sdk_matrix_pull_and_pin at build time (R4) so
	# feed_publish_write_manifest does not re-pull a possibly moved tag.
	# Otherwise pulls once and pins. RepoDigest matching is literal repo-prefix.
	local target="${1:-x86-64}" version="${2:-24.10}" digest
	if digest="$(sdk_matrix_read_digest_cache "$target" "$version")"; then
		printf '%s' "$digest"
		return 0
	fi
	sdk_matrix_pull_and_pin "$target" "$version"
}

sdk_matrix_validate_target() {
	local t
	for t in "${SDK_MATRIX_TARGETS[@]}"; do
		[[ "$1" == "$t" ]] && return 0
	done
	echo "invalid --target $1 (choose: ${SDK_MATRIX_TARGETS[*]})" >&2
	return 1
}

sdk_matrix_validate_version() {
	local v
	for v in "${SDK_MATRIX_VERSIONS[@]}"; do
		[[ "$1" == "$v" || "$1" == "$(sdk_matrix_version_patch "$1")" ]] && return 0
	done
	case "$1" in
		25.12.* | 24.10.*) return 0 ;;
	esac
	echo "invalid --version $1 (choose: ${SDK_MATRIX_VERSIONS[*]})" >&2
	return 1
}

sdk_matrix_cache_dirs() {
	local root="$1" version_label="$2"
	# Resolve relative overrides against the repo root so every consumer
	# (compose -v, cache_dirs) sees an absolute host path (luna r5).
	if [[ -n "${OWRT_SDK_DL_CACHE:-}" && "${OWRT_SDK_DL_CACHE}" != /* ]]; then
		SDK_MATRIX_DL_CACHE="${root}/${OWRT_SDK_DL_CACHE}"
	else
		SDK_MATRIX_DL_CACHE="${OWRT_SDK_DL_CACHE:-${root}/.ci-sdk-cache/dl}"
	fi
	if [[ -n "${OWRT_SDK_FEEDS_CACHE:-}" && "${OWRT_SDK_FEEDS_CACHE}" != /* ]]; then
		SDK_MATRIX_FEEDS_CACHE="${root}/${OWRT_SDK_FEEDS_CACHE}"
	else
		SDK_MATRIX_FEEDS_CACHE="${OWRT_SDK_FEEDS_CACHE:-${root}/.ci-sdk-cache/feeds/${version_label}}"
	fi
	mkdir -p "$SDK_MATRIX_DL_CACHE" "$SDK_MATRIX_FEEDS_CACHE"
	# buildbot (uid 1000) must write bind mounts; Actions runner is often 1001.
	chmod -R a+rwX "$SDK_MATRIX_DL_CACHE" "$SDK_MATRIX_FEEDS_CACHE" 2>/dev/null || true
}

sdk_matrix_compose_run() {
	local root
	root="$(sdk_matrix_root)"
	sdk_matrix_cache_dirs "$root" "$SDK_MATRIX_VERSION_LABEL"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		OWRT_SDK_DL_CACHE="$SDK_MATRIX_DL_CACHE" \
		OWRT_SDK_FEEDS_CACHE="$SDK_MATRIX_FEEDS_CACHE" \
		docker compose run --rm sdk "$@"
	)
}

sdk_matrix_export_run() {
	# Run a command in the volume-only sdk-export service (SDK volume, NO
	# workspace mount). Safe while signing keys exist in the workspace (#161):
	# the `sdk` service binds the workspace read-only and must never be
	# launched after key creation — container root could read the keys.
	local root
	root="$(sdk_matrix_root)"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm sdk-export "$@"
	)
}

sdk_matrix_feeds_lock_path() {
	local label
	label="$(sdk_matrix_version_label "$1")"
	printf '%s/scripts/feeds.lock/%s/feeds.conf' "$(sdk_matrix_root)" "$label"
}

sdk_matrix_feeds_ready() {
	# Require .config, package feeds present, and lock stamp matching the pinned
	# feeds.conf so a restored cache cannot skip refresh after pin changes.
	# #161: staging runs AFTER signing keys are written, so this probe must NOT
	# launch the workspace-mounted `sdk` service — probe via the volume-only
	# `sdk-export` service with the feeds cache bound in; the lock hash and the
	# package-source checks are evaluated host-side, never from inside a
	# container. The feeds cache holds `usrmanage` as an absolute src-link into
	# the workspace (feeds.conf), so the container cannot resolve it — the link
	# itself proves feeds update materialized the package; the checkout proves
	# the sources exist.
	local root lock cur
	root="$(sdk_matrix_root)"
	lock="${root}/scripts/feeds.lock/${SDK_MATRIX_VERSION_LABEL}/feeds.conf"
	[[ -f "$lock" ]] || return 1
	cur="$(sha256sum "$lock" | awk '{print $1}')"
	[[ -n "$cur" ]] || return 1
	# src-link target content: the package sources live in the workspace
	# checkout, which the probe container must never mount.
	[[ -f "${root}/openwrt-feed/usrmanage/Makefile" \
		&& -f "${root}/openwrt-feed/luci-app-usrmanage/Makefile" ]] || return 1
	# Initialize the cache dirs BEFORE the probe mount: docker -v auto-creates
	# missing host dirs as root, which would break a clean local build's
	# follow-up chown/buildbot init (luna r4). cache_dirs also sets the
	# absolute SDK_MATRIX_FEEDS_CACHE path used below.
	sdk_matrix_cache_dirs "$root" "$SDK_MATRIX_VERSION_LABEL"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm \
			-e "LOCK_SHA=$cur" \
			-v "${SDK_MATRIX_FEEDS_CACHE}:/builder/feeds" \
			sdk-export sh -ec '
				test -f /builder/.config || exit 1
				stamp=/builder/feeds/.usrmanage-feeds.lock.sha
				test -f "$stamp" || exit 1
				[ -n "$LOCK_SHA" ] && [ "$LOCK_SHA" = "$(cat "$stamp")" ] || exit 1
				# src-link usrmanage materializes as a symlink into the
				# workspace; the probe has no workspace mount, so check the
				# link itself (existence = feeds update ran), not its target.
				[ -L /builder/feeds/usrmanage ] || [ -d /builder/feeds/usrmanage ] || exit 1
			'
	) 2>/dev/null
}

sdk_matrix_feeds_setup() {
	local lock_path
	lock_path="$(sdk_matrix_feeds_lock_path "$SDK_MATRIX_VERSION")"
	[[ -f "$lock_path" ]] || {
		echo "missing pinned feeds lock: $lock_path" >&2
		return 1
	}
	sdk_matrix_compose_run sh -ec "
		cd /builder
		export TERM=dumb
		if [ ! -f Makefile ]; then echo 'Running ./setup.sh ...'; ./setup.sh; fi
		test -f Makefile

		cp /work/usrmanage/scripts/feeds.lock/${SDK_MATRIX_VERSION_LABEL}/feeds.conf feeds.conf
		grep -q '^src-link usrmanage' feeds.conf || echo 'src-link usrmanage /work/usrmanage/openwrt-feed' >> feeds.conf

		# Mitigate transient TLS drops from git remotes (curl 35 / shallow-info).
		git config --global http.version HTTP/1.1
		ok=0
		i=1
		while [ \"\$i\" -le 3 ]; do
			if ./scripts/feeds update base luci packages \\
				&& { [ -d feeds/base/.git ] || [ -d feeds/base_root/.git ]; } \\
				&& [ -d feeds/packages/.git ] \\
				&& [ -d feeds/luci/.git ]; then
				ok=1
				break
			fi
			echo \"feeds update failed (attempt \$i/3); wiping partial clones\" >&2
			rm -rf feeds/base feeds/base_root feeds/packages feeds/luci
			if [ \"\$i\" -eq 3 ]; then
				break
			fi
			sleep \$((i * 5))
			i=\$((i + 1))
		done
		[ \"\$ok\" -eq 1 ] || { echo 'feeds update failed after 3 attempts' >&2; exit 1; }

		./scripts/feeds install -p base liblua libucode libubox libubus libuci rpcd
		./scripts/feeds install luci-base
		./scripts/feeds update usrmanage
		./scripts/feeds install usrmanage luci-app-usrmanage
		rm -rf tmp
		make defconfig
		sha256sum /work/usrmanage/scripts/feeds.lock/${SDK_MATRIX_VERSION_LABEL}/feeds.conf \
			| awk '{print \$1}' > feeds/.usrmanage-feeds.lock.sha
	"
}

sdk_matrix_source_date_epoch() {
	if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then
		printf '%s' "$SOURCE_DATE_EPOCH"
		return
	fi
	local root epoch
	root="$(sdk_matrix_root)"
	if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		epoch="$(git -C "$root" log -1 --format=%ct 2>/dev/null || true)"
		if [[ -n "$epoch" ]]; then
			printf '%s' "$epoch"
			return
		fi
	fi
	printf '%s' '0'
}

sdk_matrix_default_jobs() {
	if [[ -n "${OWRT_MAKE_JOBS:-}" ]]; then
		printf '%s' "$OWRT_MAKE_JOBS"
		return
	fi
	local n=4
	if command -v nproc >/dev/null 2>&1; then
		n="$(nproc)"
	fi
	if (( n > 16 )); then
		n=16
	elif (( n >= 8 )); then
		n=8
	fi
	printf '%s' "$n"
}

sdk_matrix_make() {
	local -a args=()
	local jobs has_j=0 quoted sde

	sdk_matrix_feeds_ready \
		|| { echo "Run: ./scripts/docker-sdk.sh setup --target $SDK_MATRIX_TARGET --version $SDK_MATRIX_VERSION" >&2; return 1; }

	jobs="$(sdk_matrix_default_jobs)"
	for arg in "$@"; do
		case "$arg" in
			-j | -j*) has_j=1 ;;
		esac
		args+=("$arg")
	done
	[[ $has_j -eq 0 ]] && args=(-j"$jobs" "${args[@]}")
	quoted="$(printf ' %q' "${args[@]}")"
	sde="$(sdk_matrix_source_date_epoch)"
	echo "→ SOURCE_DATE_EPOCH=${sde} make package/usrmanage + luci-app-usrmanage V=s${quoted}" >&2
	sdk_matrix_compose_run sh -ec "cd /builder && export TERM=dumb SOURCE_DATE_EPOCH=${sde} && make package/usrmanage/compile package/luci-app-usrmanage/compile V=s${quoted}"
}

sdk_matrix_clean_package() {
	sdk_matrix_feeds_ready \
		|| { echo "Run: ./scripts/docker-sdk.sh setup --target $SDK_MATRIX_TARGET --version $SDK_MATRIX_VERSION" >&2; return 1; }
	sdk_matrix_compose_run sh -ec 'cd /builder && export TERM=dumb && make package/usrmanage/clean package/luci-app-usrmanage/clean V=s'
}

sdk_matrix_copy_out() {
	local root out_mount
	root="$(sdk_matrix_root)"
	out_mount="${root}/out"
	mkdir -p "${out_mount}/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}"
	(
		cd "$root"
		OWRT_SDK_IMAGE="$SDK_MATRIX_IMAGE" \
		OWRT_SDK_VOLUME="$SDK_MATRIX_VOLUME" \
		docker compose run --rm --user root -v "${out_mount}:/out" sdk sh -ec "
			dest=/out/${SDK_MATRIX_PACKAGE_ARCH}/${SDK_MATRIX_VERSION_LABEL}
			mkdir -p \"\$dest\"
			if [ -d /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/usrmanage ]; then
				cp -a /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/usrmanage \"\$dest/\"
			else
				cp -a /builder/bin/packages/${SDK_MATRIX_PACKAGE_ARCH}/. \"\$dest/\" 2>/dev/null || true
			fi
			chmod -R a+rX /out
			ls -la \"\$dest\"/usrmanage/* 2>/dev/null || ls -la \"\$dest\" 2>/dev/null || true
		"
	)
	echo "Packages under: ${SDK_MATRIX_OUT_DIR}/" >&2
}

sdk_matrix_print_row() {
	printf '  %-14s %-10s  %s\n' "$1" "$2" "$(sdk_matrix_image_tag "$1" "$2")"
}

sdk_matrix_list() {
	echo "SDK build matrix (Linux x86_64 host → ghcr.io/openwrt/sdk):" >&2
	echo "  target         version    image tag" >&2
	local target version
	for target in "${SDK_MATRIX_TARGETS[@]}"; do
		for version in "${SDK_MATRIX_VERSIONS[@]}"; do
			sdk_matrix_print_row "$target" "$version"
		done
	done
}
