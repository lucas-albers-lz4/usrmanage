#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Opt-in LuCI/rpcd login lifecycle for managed users (issue #86).
# Sourced from usrmanage-lib.sh. BusyBox ash-safe.
#
# Owned login = marker usrmanage=1 AND registry-managed username AND
# password exactly $p$<username>. Never adopt foreign luci-app-acl sections.

: "${USRMANAGE_RPCD_CONFIG:=/etc/config/rpcd}"
: "${USRMANAGE_SESSION_ACL:=luci-app-usrmanage-session}"
: "${USRMANAGE_HEALTH_ACL:=luci-app-usrmanage-health}"
: "${USRMANAGE_APP_ACL:=luci-app-usrmanage}"
# Readonly diagnostic LuCI (read list only — stock group write blocks stay denied).
: "${USRMANAGE_DIAG_STATUS_INDEX:=luci-mod-status-index}"
: "${USRMANAGE_DIAG_STATUS_ROUTES:=luci-mod-status-routes}"
: "${USRMANAGE_DIAG_STATUS_REALTIME:=luci-mod-status-realtime}"
: "${USRMANAGE_DIAG_NETWORK_CONFIG:=luci-mod-network-config}"
: "${USRMANAGE_DIAG_NETWORK_DIAG:=luci-mod-network-diagnostics}"

# --- shadow / pending --------------------------------------------------------

um_shadow_hash_usable() {
	# Non-empty, not locked (!/*). Empty hash ⇒ rpcd accepts any password.
	# First-field match only (avoid unanchored "${user}:" substring hits).
	_u=$1
	_sh=$(awk -F: -v u="$_u" '$1 == u { print $2; exit }' "$USRMANAGE_SHADOW" 2>/dev/null)
	[ -n "$_sh" ] || return 1
	case "$_sh" in
		'!'*|'*'*) return 1 ;;
	esac
	return 0
}

um_rpcd_pending_ok() {
	# Refuse if another operator has staged rpcd UCI deltas.
	if ! command -v uci >/dev/null 2>&1; then
		return 0
	fi
	_ch=$(uci changes rpcd 2>/dev/null || true)
	[ -z "$_ch" ]
}

# --- session revoke ----------------------------------------------------------

um_session_revoke_user() {
	# Destroy ubus sessions whose username matches. Required when ubus
	# exists; DRY_RUN without jsonfilter skips (host tests). A host without
	# ubus has no LuCI sessions to revoke, so a missing ubus binary is treated
	# as success (issue #92). Fail closed on device if ubus exists but
	# list/query tooling is unavailable.
	#
	# Username field path (QEMU 24.10.8 lab, issue #95): session get exposes
	# @.values.username; session login replies use data.username. Keep both
	# jsonfilter fallbacks for compatibility across rpcd shapes.
	_u=$1
	if ! command -v ubus >/dev/null 2>&1; then
		return 0
	fi
	if ! command -v jsonfilter >/dev/null 2>&1; then
		if [ "${USRMANAGE_DRY_RUN:-0}" = "1" ]; then
			return 0
		fi
		return 1
	fi
	_raw=$(ubus call session list 2>/dev/null) || return 1
	[ -n "$_raw" ] || return 0
	# Field-anchor on ubus_rpc_session — never greedily match any 32-char hex
	# in the blob (ACL / payload noise caused session_revoke_unavailable).
	_sid_list=$(printf '%s' "$_raw" \
		| grep -oE '"ubus_rpc_session":[[:space:]]*"[0-9a-f]{32}"' \
		| grep -oE '[0-9a-f]{32}' | sort -u)
	for _sid in $_sid_list; do
		[ -n "$_sid" ] || continue
		# One ubus call per session; capture its exit status separately so a
		# failed query fails closed (a live session could survive otherwise).
		# A missing/empty username field is a skip, NOT a failure (rpcd's own
		# sessions and other principals have no username).
		_su=$(ubus call session get "{\"ubus_rpc_session\":\"${_sid}\"}" 2>/dev/null)
		_rc=$?
		[ "$_rc" = "0" ] || return 1
		_su2=$(printf '%s' "$_su" | jsonfilter -e '@.values.username' 2>/dev/null) || _su2=
		[ -n "$_su2" ] || _su2=$(printf '%s' "$_su" | jsonfilter -e '@.data.username' 2>/dev/null) || _su2=
		[ "$_su2" = "$_u" ] || continue
		ubus call session destroy "{\"ubus_rpc_session\":\"${_sid}\"}" >/dev/null 2>&1 || return 1
	done
	return 0
}

um_session_user_has_live_sid() {
	# 0 if a live ubus SID still exists for username. No ubus → 1 (none).
	# Missing jsonfilter on a real device is fail-closed (cannot prove absence).
	_u=$1
	if ! command -v ubus >/dev/null 2>&1; then
		return 1
	fi
	if ! command -v jsonfilter >/dev/null 2>&1; then
		if [ "${USRMANAGE_DRY_RUN:-0}" = "1" ]; then
			return 1
		fi
		return 0
	fi
	_raw=$(ubus call session list 2>/dev/null) || return 0
	[ -n "$_raw" ] || return 1
	_sid_list=$(printf '%s' "$_raw" \
		| grep -oE '"ubus_rpc_session":[[:space:]]*"[0-9a-f]{32}"' \
		| grep -oE '[0-9a-f]{32}' | sort -u)
	for _sid in $_sid_list; do
		[ -n "$_sid" ] || continue
		_su=$(ubus call session get "{\"ubus_rpc_session\":\"${_sid}\"}" 2>/dev/null) || return 0
		_su2=$(printf '%s' "$_su" | jsonfilter -e '@.values.username' 2>/dev/null) || _su2=
		[ -n "$_su2" ] || _su2=$(printf '%s' "$_su" | jsonfilter -e '@.data.username' 2>/dev/null) || _su2=
		[ "$_su2" = "$_u" ] && return 0
	done
	return 1
}

um_session_revoke_required() {
	_u=$1
	um_session_revoke_user "$_u" && return 0
	um_audit fail "$_u" fail session_revoke_unavailable
	um_die "error: session_revoke_unavailable"
}

# --- rpcd config parse / write -----------------------------------------------

# Dump login sections as records:
# INDEX\x1fUSERNAME\x1fPASSWORD\x1fMARKER\x1fREADS\x1fWRITES\x1fSCOPE
# INDEX is 0-based among login sections only. READS/WRITES are comma-separated.
# SCOPE is option usrmanage_scope (empty when missing → role-derived via
# um_luci_login_scope_for_role). Delimiter is ASCII unit separator (\x1f) —
# safe in $p$ refs and base64 hashes, unlike | which can appear in foreign
# plaintext passwords (issue #98 m3).
um_luci_login_sep() {
	# ASCII unit separator (0x1f) via POSIX octal escape — dash printf does not
	# interpret \x hex, so \037 is the portable form. Safe in $p$ refs/base64.
	printf '\037'
}

um_rpcd_login_dump() {
	_ull_cfg=$USRMANAGE_RPCD_CONFIG
	[ -f "$_ull_cfg" ] || return 0
	awk '
	BEGIN { idx = -1; inlogin = 0; OFS = sprintf("%c", 31) }
	function flush() {
		if (!inlogin) return
		printf "%d%s%s%s%s%s%s%s%s%s%s%s%s\n", idx, OFS, user, OFS, pass, OFS, marker, OFS, reads, OFS, writes, OFS, scope
		user = ""; pass = ""; marker = ""; reads = ""; writes = ""; scope = ""
	}
	/^config[ \t]+login([ \t]|$)/ {
		flush()
		idx++
		inlogin = 1
		next
	}
	/^config[ \t]/ {
		flush()
		inlogin = 0
		next
	}
	!inlogin { next }
	{
		line = $0
		sub(/^[ \t]+/, "", line)
		if (line ~ /^option[ \t]+username[ \t]+/) {
			sub(/^option[ \t]+username[ \t]+/, "", line)
			gsub(/^'\''|'\''$/, "", line)
			gsub(/^"|"$/, "", line)
			user = line
		} else if (line ~ /^option[ \t]+password[ \t]+/) {
			sub(/^option[ \t]+password[ \t]+/, "", line)
			gsub(/^'\''|'\''$/, "", line)
			gsub(/^"|"$/, "", line)
			pass = line
		} else if (line ~ /^option[ \t]+usrmanage_scope[ \t]+/) {
			sub(/^option[ \t]+usrmanage_scope[ \t]+/, "", line)
			gsub(/^'\''|'\''$/, "", line)
			gsub(/^"|"$/, "", line)
			scope = line
		} else if (line ~ /^option[ \t]+usrmanage[ \t]+/) {
			sub(/^option[ \t]+usrmanage[ \t]+/, "", line)
			gsub(/^'\''|'\''$/, "", line)
			gsub(/^"|"$/, "", line)
			marker = line
		} else if (line ~ /^list[ \t]+read[ \t]+/) {
			sub(/^list[ \t]+read[ \t]+/, "", line)
			gsub(/^'\''|'\''$/, "", line)
			gsub(/^"|"$/, "", line)
			if (reads != "") reads = reads ","
			reads = reads line
		} else if (line ~ /^list[ \t]+write[ \t]+/) {
			sub(/^list[ \t]+write[ \t]+/, "", line)
			gsub(/^'\''|'\''$/, "", line)
			gsub(/^"|"$/, "", line)
			if (writes != "") writes = writes ","
			writes = writes line
		}
	}
	END { flush() }
	' "$_ull_cfg"
}

um_luci_login_acl_sorted() {
	# Normalize comma-separated ACL list to sorted unique CSV on stdout.
	# Busybox-safe: avoid `paste -sd,` which is not present in the minimal
	# OpenWrt feed-smoke image (and not a declared DEPENDS). tr+sed does the
	# same newline→comma join without the external paste binary.
	_raw=$1
	[ -n "$_raw" ] || { printf ''; return 0; }
	printf '%s' "$_raw" | tr ',' '\n' | sed '/^$/d' | sort -u | tr '\n' ',' | sed 's/,$//'
}

um_luci_login_scope_for_role() {
	# um_luci_login_scope_for_role <role> → full|diagnostic (1 if invalid role).
	case "$1" in
		admin) printf 'full'; return 0 ;;
		readonly) printf 'diagnostic'; return 0 ;;
		*) return 1 ;;
	esac
}

um_luci_login_normalize_scope() {
	# um_luci_login_normalize_scope <scope> → diagnostic|full on stdout; 1 if invalid.
	# Legacy usrmanage_scope 'app' maps to diagnostic.
	_sc=$1
	[ -n "$_sc" ] || return 1
	case "$_sc" in
		full)
			printf 'full'
			return 0
			;;
		diagnostic|app)
			printf 'diagnostic'
			return 0
			;;
		*)
			return 1
			;;
	esac
}

um_luci_login_csv_has_literal_star() {
	# Exact token "*" in a CSV. noglob so unquoted * cannot expand.
	_csv=$1
	[ -n "$_csv" ] || return 1
	_old_ifs=$IFS
	IFS=,
	set -f
	# shellcheck disable=SC2086
	set -- ${_csv}
	set +f
	IFS=$_old_ifs
	for _t in "$@"; do
		[ "$_t" = "*" ] && return 0
	done
	return 1
}

um_luci_login_csv_has_forbidden_readonly() {
	# luci-base is never allowed on readonly (logout ACL / full UCI write).
	# Diagnostic luci-mod-* names are allowed only via exact expected-set match.
	_csv=$1
	[ -n "$_csv" ] || return 1
	_old_ifs=$IFS
	IFS=,
	set -f
	# shellcheck disable=SC2086
	set -- ${_csv}
	set +f
	IFS=$_old_ifs
	for _t in "$@"; do
		[ "$_t" = "luci-base" ] && return 0
	done
	return 1
}

um_luci_login_expected_reads() {
	# um_luci_login_expected_reads <role> [scope ignored — derived from role]
	_role=$1
	_scope=$(um_luci_login_scope_for_role "$_role") || { printf ''; return 1; }
	if [ "$_scope" = "full" ]; then
		printf '*'
		return 0
	fi
	# diagnostic (readonly): session + health + view-only UM + status/network.
	printf '%s,%s,%s,%s,%s,%s,%s,%s' \
		"$USRMANAGE_SESSION_ACL" \
		"$USRMANAGE_HEALTH_ACL" \
		"$USRMANAGE_APP_ACL" \
		"$USRMANAGE_DIAG_STATUS_INDEX" \
		"$USRMANAGE_DIAG_STATUS_ROUTES" \
		"$USRMANAGE_DIAG_STATUS_REALTIME" \
		"$USRMANAGE_DIAG_NETWORK_CONFIG" \
		"$USRMANAGE_DIAG_NETWORK_DIAG" \
		| tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
}

um_luci_login_expected_writes() {
	# um_luci_login_expected_writes <role> [scope ignored — derived from role]
	_role=$1
	_scope=$(um_luci_login_scope_for_role "$_role") || { printf ''; return 1; }
	if [ "$_scope" = "full" ]; then
		printf '*'
	else
		printf ''
	fi
}

um_luci_login_acls_match_role() {
	# um_luci_login_acls_match_role <role> <reads_csv> <writes_csv> [scope]
	# Exact set equality on sorted CSV strings (never unquoted glob).
	# Scope must match role lock (admin→full, readonly→diagnostic).
	_role=$1
	_want_scope=$(um_luci_login_scope_for_role "$_role") || return 1
	if [ -n "${4:-}" ]; then
		_scope=$(um_luci_login_normalize_scope "$4") || return 1
		[ "$_scope" = "$_want_scope" ] || return 1
	else
		_scope=$_want_scope
	fi
	_reads=$(um_luci_login_acl_sorted "$2")
	_writes=$(um_luci_login_acl_sorted "$3")
	_ereads=$(um_luci_login_expected_reads "$_role") || return 1
	_ewrites=$(um_luci_login_expected_writes "$_role") || return 1
	[ "$_reads" = "$_ereads" ] || return 1
	[ "$_writes" = "$_ewrites" ] || return 1
	if um_luci_login_csv_has_literal_star "$_reads" || um_luci_login_csv_has_literal_star "$_writes"; then
		[ "$_role" = "admin" ] && [ "$_scope" = "full" ] || return 1
	fi
	if [ "$_role" = "readonly" ]; then
		um_luci_login_csv_has_literal_star "$_reads" && return 1
		um_luci_login_csv_has_literal_star "$_writes" && return 1
		um_luci_login_csv_has_forbidden_readonly "$_reads" && return 1
		um_luci_login_csv_has_forbidden_readonly "$_writes" && return 1
	fi
	return 0
}

um_luci_login_classify_row() {
	# args: username password marker reads writes want_user [scope]
	# prints owned|foreign|tampered|skip
	_row_user=$1
	_row_pass=$2
	_row_mark=$3
	_row_reads=$4
	_row_writes=$5
	_want=$6
	_row_scope=$7
	[ "$_row_user" = "$_want" ] || { printf 'skip'; return 0; }
	_expect_pass="\$p\$${_want}"
	if [ "$_row_mark" = "1" ]; then
		if um_is_managed "$_want" && [ "$_row_pass" = "$_expect_pass" ]; then
			_role=$(um_role_of "$_want")
			if [ -z "$_row_scope" ]; then
				_row_scope=$(um_luci_login_scope_for_role "$_role") || _row_scope=
			fi
			if um_luci_login_acls_match_role "$_role" "$_row_reads" "$_row_writes" "$_row_scope"; then
				printf 'owned'
			else
				printf 'tampered'
			fi
		else
			printf 'tampered'
		fi
	else
		printf 'foreign'
	fi
}

um_rpcd_config_parsable() {
	# Fail closed when /etc/config/rpcd contains a libuci-valid form that
	# um_rpcd_login_dump's awk grammar cannot see (L4 / issue #108 / #118 L8/L9):
	# indented section headers, single-letter keyword abbreviations, quoted
	# section type, quoted option/list keys, or trailing # comments on
	# option/list lines. Never report state=none / disable=ok for such a file.
	_ull_cfg=$USRMANAGE_RPCD_CONFIG
	[ -f "$_ull_cfg" ] || return 0
	# Indented config/option/list section header (libuci skip_whitespace first).
	if grep -qE '^[[:space:]]+config[[:space:]]' "$_ull_cfg" 2>/dev/null; then
		return 1
	fi
	# Abbreviated keywords: lone c / o / l as the first word (optionally indented).
	if grep -qE '^[[:space:]]*[col]([[:space:]]|$)' "$_ull_cfg" 2>/dev/null; then
		return 1
	fi
	# Quoted section type: config 'login' / config "login"
	if grep -qE '^config[[:space:]]+["'\'']' "$_ull_cfg" 2>/dev/null; then
		return 1
	fi
	# Quoted option/list keys: option 'username' / list "write" (L8).
	if grep -qE '^[[:space:]]*(option|list)[[:space:]]+["'\'']' "$_ull_cfg" 2>/dev/null; then
		return 1
	fi
	# Trailing # comments on option/list lines — dump would absorb them into
	# the value (L9). Bare "#" inside a quoted value is also refused (fail closed).
	if grep -qE '^[[:space:]]*(option|list)[[:space:]].*#' "$_ull_cfg" 2>/dev/null; then
		return 1
	fi
	return 0
}

um_luci_login_state() {
	# um_luci_login_state <user> → none|owned|foreign|tampered
	# Returns 1 on internal failure (e.g. mktemp) — callers must treat
	# this as a hard error, never as 'none' (issue #97 M6).
	_ull_name=$1
	um_rpcd_config_parsable || {
		um_audit fail "$_ull_name" fail rpcd_config_unparsable
		return 1
	}
	_owned=0
	_foreign=0
	_tampered=0
	_stf=$(mktemp "${TMPDIR:-/tmp}/um-luci-st.XXXXXX") || {
		um_audit fail "$_ull_name" fail luci_login_state_tmp
		return 1
	}
	_uf=$(um_luci_login_sep)
	um_rpcd_login_dump | while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw _rs || [ -n "${_i:-}" ]; do
		[ -n "${_i:-}" ] || continue
		_cls=$(um_luci_login_classify_row "$_ru" "$_rp" "$_rm" "$_rr" "$_rw" "$_ull_name" "$_rs")
		case "$_cls" in
			owned) printf 'O\n' ;;
			foreign) printf 'F\n' ;;
			tampered) printf 'T\n' ;;
		esac
	done > "$_stf"
	while IFS= read -r _c || [ -n "${_c:-}" ]; do
		case "$_c" in
			O) _owned=$((_owned + 1)) ;;
			F) _foreign=$((_foreign + 1)) ;;
			T) _tampered=$((_tampered + 1)) ;;
		esac
	done < "$_stf"
	rm -f "$_stf"
	# Fail closed (#150): a tampered owned login must not keep live elevated
	# ubus sessions. Revoke best-effort — idempotent (list then destroy), so
	# repeated state queries do not spam. Never rewrite the ACL section
	# (forensics preserved) and never delete the login here.
	if [ "$_tampered" -gt 0 ]; then
		um_session_revoke_user "$_ull_name" || true
	fi
	if [ "$_tampered" -gt 0 ] || [ "$_owned" -gt 1 ]; then
		printf 'tampered'
	elif [ "$_foreign" -gt 0 ]; then
		printf 'foreign'
	elif [ "$_owned" -eq 1 ]; then
		printf 'owned'
	else
		printf 'none'
	fi
}

um_luci_login_ours_index() {
	# Index of login we claim: marker + $p$user (+ managed when still registered).
	# Pass skip_managed=1 as $2 for del cleanup after unregister.
	# Returns ALL matching indexes (newline-separated) — callers must handle
	# multiple owned sections (issue #98 m6).
	_ull_name=$1
	_ull_skip_managed=${2:-0}
	_expect_pass="\$p\$${_ull_name}"
	_uf=$(um_luci_login_sep)
	um_rpcd_login_dump | while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw _rs || [ -n "$_i" ]; do
		[ "$_ru" = "$_ull_name" ] || continue
		[ "$_rm" = "1" ] || continue
		[ "$_rp" = "$_expect_pass" ] || continue
		if [ "$_ull_skip_managed" != "1" ]; then
			um_is_managed "$_ull_name" || continue
		fi
		printf '%s\n' "$_i"
	done
}

um_luci_login_owned_index() {
	# Owned = ours + exact role ACL matrix.
	# Returns ALL matching indexes (newline-separated) — callers must handle
	# multiple owned sections (issue #98 m6).
	_ull_name=$1
	_expect_pass="\$p\$${_ull_name}"
	_role=$(um_role_of "$_ull_name")
	_uf=$(um_luci_login_sep)
	um_rpcd_login_dump | while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw _rs || [ -n "$_i" ]; do
		[ "$_ru" = "$_ull_name" ] || continue
		[ "$_rm" = "1" ] || continue
		[ "$_rp" = "$_expect_pass" ] || continue
		um_is_managed "$_ull_name" || continue
		um_luci_login_acls_match_role "$_role" "$_rr" "$_rw" "$_rs" || continue
		printf '%s\n' "$_i"
	done
}

um_rpcd_rewrite_without_login_index() {
	# Remove login section at 0-based index among login sections; write to stdout.
	_ull_in=$1
	_ull_drop=$2
	[ -f "$_ull_in" ] || return 0
	awk -v drop="$_ull_drop" '
	BEGIN { idx = -1; inlogin = 0; skip = 0 }
	/^config[ \t]+login([ \t]|$)/ {
		idx++
		if (idx == drop + 0) { skip = 1; next }
		skip = 0
		inlogin = 1
		print
		next
	}
	/^config[ \t]/ {
		skip = 0
		inlogin = 0
		print
		next
	}
	skip { next }
	{ print }
	' "$_ull_in"
}

um_rpcd_append_owned_login() {
	# Append owned login section for user/role to file path $1 (already exists).
	# Scope is always derived from role (admin→full, readonly→diagnostic).
	# um_rpcd_append_owned_login <file> <user> <role> [ignored_scope]
	_ull_out=$1
	_ull_uname=$2
	_ull_urole=$3
	_ull_scope=$(um_luci_login_scope_for_role "$_ull_urole") || _ull_scope=diagnostic
	{
		printf '\nconfig login\n'
		printf '\toption username '\''%s'\''\n' "$_ull_uname"
		# Literal $p$username for rpcd UNIX-password login (not shell expansion).
		# shellcheck disable=SC2016
		printf '\toption password '\''$p$%s'\''\n' "$_ull_uname"
		printf '\toption usrmanage '\''1'\''\n'
		printf '\toption usrmanage_scope '\''%s'\''\n' "$_ull_scope"
		if [ "$_ull_scope" = "full" ]; then
			printf '\tlist read '\''*'\''\n'
			printf '\tlist write '\''*'\''\n'
		else
			# diagnostic: read-only stock + usrmanage groups (empty write list).
			printf '\tlist read '\''%s'\''\n' "$USRMANAGE_SESSION_ACL"
			printf '\tlist read '\''%s'\''\n' "$USRMANAGE_HEALTH_ACL"
			printf '\tlist read '\''%s'\''\n' "$USRMANAGE_APP_ACL"
			printf '\tlist read '\''%s'\''\n' "$USRMANAGE_DIAG_STATUS_INDEX"
			printf '\tlist read '\''%s'\''\n' "$USRMANAGE_DIAG_STATUS_ROUTES"
			printf '\tlist read '\''%s'\''\n' "$USRMANAGE_DIAG_STATUS_REALTIME"
			printf '\tlist read '\''%s'\''\n' "$USRMANAGE_DIAG_NETWORK_CONFIG"
			printf '\tlist read '\''%s'\''\n' "$USRMANAGE_DIAG_NETWORK_DIAG"
		fi
	} >> "$_ull_out"
}

um_rpcd_atomic_replace() {
	# Stage beside destination to avoid EXDEV (tmpfs /tmp → overlay /etc).
	# Preserve destination mode (OpenWrt ships /etc/config/rpcd as 0600 via
	# INSTALL_CONF). Hardcoding 0644 was L5 — first set-luci-login world-readable.
	# Use _ull_fmode (not _ull_mode): the latter is the enable/disable/reset
	# argument in um_mut_set_luci_login and must not be clobbered (ash globals).
	_ull_from=$1
	_ull_to=$2
	_ull_todir=$(dirname "$_ull_to")
	_ull_fmode=600
	if [ -f "$_ull_to" ]; then
		_ull_got=$(stat -c '%a' "$_ull_to" 2>/dev/null) || _ull_got=
		case "$_ull_got" in
			[0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) _ull_fmode=$_ull_got ;;
		esac
	fi
	_ull_stage=$(mktemp "${_ull_todir}/.usrmanage-rpcd.XXXXXX") || return 1
	cp "$_ull_from" "$_ull_stage" || { rm -f "$_ull_stage"; return 1; }
	chmod "$_ull_fmode" "$_ull_stage" 2>/dev/null || true
	chown 0:0 "$_ull_stage" 2>/dev/null || true
	mv "$_ull_stage" "$_ull_to" || { rm -f "$_ull_stage"; return 1; }
	return 0
}

um_luci_login_verify_owned_acls() {
	# After write, confirm ours section has exact role ACL membership.
	_ull_name=$1
	_ull_role=$2
	_ull_scope=$(um_luci_login_scope_for_role "$_ull_role") || return 1
	_ull_idx=$(um_luci_login_ours_index "$_ull_name" | head -n1)
	[ -n "$_ull_idx" ] || return 1
	_uf=$(um_luci_login_sep)
	_row=$(um_rpcd_login_dump | awk -v i="$_ull_idx" -v FS="$_uf" '$1==i {print; exit}')
	_reads=$(printf '%s' "$_row" | awk -v FS="$_uf" '{print $5}')
	_writes=$(printf '%s' "$_row" | awk -v FS="$_uf" '{print $6}')
	_got_scope=$(printf '%s' "$_row" | awk -v FS="$_uf" '{print $7}')
	_got_scope=$(um_luci_login_normalize_scope "$_got_scope") || return 1
	[ "$_got_scope" = "$_ull_scope" ] || return 1
	um_luci_login_acls_match_role "$_ull_role" "$_reads" "$_writes" "$_ull_scope"
}

um_luci_login_read_ours_scope() {
	# Scope recorded on the first ours section; default from role when missing.
	_ull_name=$1
	_ull_role=$(um_role_of "$_ull_name" 2>/dev/null || printf 'readonly')
	_ull_idx=$(um_luci_login_ours_index "$_ull_name" | head -n1)
	[ -n "$_ull_idx" ] || {
		um_luci_login_scope_for_role "$_ull_role" || printf 'diagnostic'
		return 0
	}
	_uf=$(um_luci_login_sep)
	_row=$(um_rpcd_login_dump | awk -v i="$_ull_idx" -v FS="$_uf" '$1==i {print; exit}')
	_got=$(printf '%s' "$_row" | awk -v FS="$_uf" '{print $7}')
	if [ -n "$_got" ]; then
		um_luci_login_normalize_scope "$_got" && return 0
	fi
	um_luci_login_scope_for_role "$_ull_role" || printf 'diagnostic'
}

um_luci_login_enable_user() {
	# Create owned login for managed user. Caller holds flock.
	# um_luci_login_enable_user <user> [ignored_scope — always role-derived]
	# Returns 0/1; sets UM_LUCI_ERR on failure (no um_die — add path must rollback).
	_ull_name=$1
	_ull_role=$(um_role_of "$_ull_name")
	_ull_scope=$(um_luci_login_scope_for_role "$_ull_role") || {
		UM_LUCI_ERR=invalid_luci_scope
		return 1
	}
	UM_LUCI_ERR=
	um_rpcd_config_parsable || {
		um_audit denied "$_ull_name" denied rpcd_config_unparsable "$_ull_role"
		UM_LUCI_ERR=rpcd_config_unparsable
		return 1
	}
	if [ "$_ull_scope" = "full" ]; then
		# Invisible / unparsable * must not be written (Luna D4 / #108).
		um_rpcd_config_parsable || {
			um_audit denied "$_ull_name" denied rpcd_config_unparsable "$_ull_role"
			UM_LUCI_ERR=rpcd_config_unparsable
			return 1
		}
	fi
	um_rpcd_pending_ok || {
		um_audit denied "$_ull_name" denied rpcd_pending_changes "$_ull_role"
		UM_LUCI_ERR=rpcd_pending_changes
		return 1
	}
	um_shadow_hash_usable "$_ull_name" || {
		um_audit denied "$_ull_name" denied no_password "$_ull_role"
		UM_LUCI_ERR=no_password
		return 1
	}
	_ull_st=$(um_luci_login_state "$_ull_name") || {
		um_audit fail "$_ull_name" fail luci_login_state "$_ull_role"
		UM_LUCI_ERR=luci_login_state
		return 1
	}
	case "$_ull_st" in
		none) ;;
		owned)
			um_luci_login_sync_acls "$_ull_name" "$_ull_role" || {
				UM_LUCI_ERR=luci_login_sync_failed
				return 1
			}
			return 0
			;;
		foreign)
			um_audit denied "$_ull_name" denied login_exists_foreign "$_ull_role"
			UM_LUCI_ERR=login_exists_foreign
			return 1
			;;
		tampered)
			um_audit denied "$_ull_name" denied login_tampered "$_ull_role"
			UM_LUCI_ERR=login_tampered
			return 1
			;;
		*)
			UM_LUCI_ERR=luci_login_state
			return 1
			;;
	esac
	_ull_dest=$USRMANAGE_RPCD_CONFIG
	_ull_dir=$(dirname "$_ull_dest")
	[ -d "$_ull_dir" ] || mkdir -p "$_ull_dir" || {
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	[ -f "$_ull_dest" ] || printf '\n' > "$_ull_dest"
	_ull_work=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || {
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	cp "$_ull_dest" "$_ull_work" || {
		rm -f "$_ull_work"
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	um_rpcd_append_owned_login "$_ull_work" "$_ull_name" "$_ull_role"
	um_rpcd_atomic_replace "$_ull_work" "$_ull_dest" || {
		rm -f "$_ull_work"
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	rm -f "$_ull_work"
	um_luci_login_verify_owned_acls "$_ull_name" "$_ull_role" || {
		_ull_rollback_idxs=$(um_luci_login_ours_index "$_ull_name")
		# Process in reverse to avoid index shifting.
		_ull_rollback_rev=$(printf '%s' "$_ull_rollback_idxs" | sort -nr)
		for _ull_rollback_idx in $_ull_rollback_rev; do
			[ -n "$_ull_rollback_idx" ] || continue
			_ull_tmp2=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || true
			if [ -n "$_ull_tmp2" ]; then
				um_rpcd_rewrite_without_login_index "$_ull_dest" "$_ull_rollback_idx" > "$_ull_tmp2" \
					&& um_rpcd_atomic_replace "$_ull_tmp2" "$_ull_dest"
				rm -f "$_ull_tmp2"
			fi
		done
		um_audit fail "$_ull_name" fail luci_acl_verify "$_ull_role"
		UM_LUCI_ERR=luci_acl_verify_failed
		return 1
	}
	_ull_acl=r
	[ "$_ull_scope" = "full" ] && _ull_acl=star
	um_audit luci_grant "$_ull_name" ok "acl=${_ull_acl} scope=${_ull_scope}" "$_ull_role"
	return 0
}

um_luci_login_disable_user() {
	_ull_name=$1
	_ull_role=$(um_role_of "$_ull_name" 2>/dev/null || printf 'readonly')
	UM_LUCI_ERR=
	um_rpcd_config_parsable || {
		# Still destroy live sessions before refusing — elevated ACLs must
		# not linger until expiry when rpcd is unparsable (Bugbot #113).
		um_session_revoke_user "$_ull_name" || {
			um_audit fail "$_ull_name" fail session_revoke_unavailable
			UM_LUCI_ERR=session_revoke_unavailable
			return 1
		}
		um_audit denied "$_ull_name" denied rpcd_config_unparsable "$_ull_role"
		UM_LUCI_ERR=rpcd_config_unparsable
		return 1
	}
	um_rpcd_pending_ok || {
		um_audit denied "$_ull_name" denied rpcd_pending_changes "$_ull_role"
		UM_LUCI_ERR=rpcd_pending_changes
		return 1
	}
	_ull_idxs=$(um_luci_login_ours_index "$_ull_name")
	_ull_st=$(um_luci_login_state "$_ull_name") || {
		um_audit fail "$_ull_name" fail luci_login_state "$_ull_role"
		UM_LUCI_ERR=luci_login_state
		return 1
	}
	# Prefer removing our section even when a foreign login coexists (state=foreign).
	if [ -z "$_ull_idxs" ]; then
		case "$_ull_st" in
			none)
				um_session_revoke_user "$_ull_name" || {
					um_audit fail "$_ull_name" fail session_revoke_unavailable
					UM_LUCI_ERR=session_revoke_unavailable
					return 1
				}
				um_audit luci_revoke "$_ull_name" ok "acl=none" "$_ull_role"
				return 0
				;;
			foreign)
				um_audit denied "$_ull_name" denied login_exists_foreign "$_ull_role"
				UM_LUCI_ERR=login_exists_foreign
				return 1
				;;
			tampered)
				um_audit denied "$_ull_name" denied login_tampered "$_ull_role"
				UM_LUCI_ERR=login_tampered
				return 1
				;;
			*)
				UM_LUCI_ERR=luci_login_state
				return 1
				;;
		esac
	fi
	# Revoke live sessions before deleting the login definition.
	um_session_revoke_user "$_ull_name" || {
		um_audit fail "$_ull_name" fail session_revoke_unavailable
		UM_LUCI_ERR=session_revoke_unavailable
		return 1
	}
	# Remove ALL matching owned indexes (issue #98 m6).
	_ull_dir=$(dirname "$USRMANAGE_RPCD_CONFIG")
	_ull_tmp=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || {
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	cp "$USRMANAGE_RPCD_CONFIG" "$_ull_tmp" || {
		rm -f "$_ull_tmp"
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	# Process in reverse to avoid index shifting when removing multiple.
	_ull_rev_idxs=$(printf '%s' "$_ull_idxs" | sort -nr)
	for _ull_idx in $_ull_rev_idxs; do
		[ -n "$_ull_idx" ] || continue
		_ull_tmp2=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || {
			rm -f "$_ull_tmp"
			UM_LUCI_ERR=rpcd_config_failed
			return 1
		}
		um_rpcd_rewrite_without_login_index "$_ull_tmp" "$_ull_idx" > "$_ull_tmp2" || {
			rm -f "$_ull_tmp" "$_ull_tmp2"
			UM_LUCI_ERR=rpcd_config_failed
			return 1
		}
		mv "$_ull_tmp2" "$_ull_tmp" || {
			rm -f "$_ull_tmp" "$_ull_tmp2"
			UM_LUCI_ERR=rpcd_config_failed
			return 1
		}
	done
	um_rpcd_atomic_replace "$_ull_tmp" "$USRMANAGE_RPCD_CONFIG" || {
		rm -f "$_ull_tmp"
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	rm -f "$_ull_tmp"
	um_audit luci_revoke "$_ull_name" ok "acl=none" "$_ull_role"
	return 0
}

um_luci_login_sync_acls() {
	# Recreate our login section with role-correct ACLs (delete + append).
	# um_luci_login_sync_acls <user> <role> [ignored_scope — always role-derived]
	# Works for owned and ACL-drifted (marker+$p$+managed) sections.
	# Handles multiple matching indexes (issue #98 m6).
	_ull_name=$1
	_ull_role=$2
	_ull_scope=$(um_luci_login_scope_for_role "$_ull_role") || return 1
	# Refuse rewrite when awk cannot see the whole file (mixed canonical +
	# hidden unparsable login must not leave elevated web access).
	um_rpcd_config_parsable || return 1
	_ull_idxs=$(um_luci_login_ours_index "$_ull_name")
	[ -n "$_ull_idxs" ] || return 0
	um_rpcd_pending_ok || return 1
	_ull_dir=$(dirname "$USRMANAGE_RPCD_CONFIG")
	_ull_tmp=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || return 1
	cp "$USRMANAGE_RPCD_CONFIG" "$_ull_tmp" || {
		rm -f "$_ull_tmp"
		return 1
	}
	# Remove all matching indexes, then append one correct section.
	# Process in reverse to avoid index shifting.
	_ull_rev_idxs=$(printf '%s' "$_ull_idxs" | sort -nr)
	for _ull_idx in $_ull_rev_idxs; do
		[ -n "$_ull_idx" ] || continue
		_ull_tmp2=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || {
			rm -f "$_ull_tmp"
			return 1
		}
		um_rpcd_rewrite_without_login_index "$_ull_tmp" "$_ull_idx" > "$_ull_tmp2" || {
			rm -f "$_ull_tmp" "$_ull_tmp2"
			return 1
		}
		mv "$_ull_tmp2" "$_ull_tmp" || {
			rm -f "$_ull_tmp" "$_ull_tmp2"
			return 1
		}
	done
	um_rpcd_append_owned_login "$_ull_tmp" "$_ull_name" "$_ull_role"
	um_rpcd_atomic_replace "$_ull_tmp" "$USRMANAGE_RPCD_CONFIG" || {
		rm -f "$_ull_tmp"
		return 1
	}
	rm -f "$_ull_tmp"
	um_luci_login_verify_owned_acls "$_ull_name" "$_ull_role" || return 1
	return 0
}

um_luci_login_reset_user() {
	# Recovery path (issue #93 M2): remove ANY usrmanage-claimed login section
	# (marker + $p$ or marker-only) for the user, regardless of password match.
	# Does NOT touch a pure foreign section (no marker).
	# Clears a tampered state back to none (or foreign if a foreign section remains).
	# Caller holds flock. Returns 0/1; sets UM_LUCI_ERR on failure.
	_ull_name=$1
	_ull_role=$(um_role_of "$_ull_name" 2>/dev/null || printf 'readonly')
	UM_LUCI_ERR=
	um_rpcd_config_parsable || {
		um_audit denied "$_ull_name" denied rpcd_config_unparsable "$_ull_role"
		UM_LUCI_ERR=rpcd_config_unparsable
		return 1
	}
	um_rpcd_pending_ok || {
		um_audit denied "$_ull_name" denied rpcd_pending_changes "$_ull_role"
		UM_LUCI_ERR=rpcd_pending_changes
		return 1
	}
	# Find ALL sections with our marker for this user (any password — we reset them).
	_uf=$(um_luci_login_sep)
	_ull_marker_idxs=$(um_rpcd_login_dump | while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw _rs || [ -n "$_i" ]; do
		[ "$_ru" = "$_ull_name" ] || continue
		[ "$_rm" = "1" ] || continue
		printf '%s\n' "$_i"
	done)
	if [ -z "$_ull_marker_idxs" ]; then
		# No marked sections — nothing to reset. Audit and succeed.
		# Do NOT revoke sessions here: with no usrmanage-marked section,
		# any login is foreign, and username-based session matching cannot
		# tell which sessions belong to it — revoking would destroy the
		# foreign application's active sessions (issue #98 m4).
		um_audit luci_revoke "$_ull_name" ok "acl=none" "$_ull_role"
		return 0
	fi
	# Revoke live sessions before removing login definitions.
	um_session_revoke_user "$_ull_name" || {
		um_audit fail "$_ull_name" fail session_revoke_unavailable
		UM_LUCI_ERR=session_revoke_unavailable
		return 1
	}
	# Remove ALL marked sections.
	_ull_dir=$(dirname "$USRMANAGE_RPCD_CONFIG")
	_ull_tmp=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || {
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	cp "$USRMANAGE_RPCD_CONFIG" "$_ull_tmp" || {
		rm -f "$_ull_tmp"
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	# Process in reverse to avoid index shifting.
	_ull_rev_marker_idxs=$(printf '%s' "$_ull_marker_idxs" | sort -nr)
	for _ull_idx in $_ull_rev_marker_idxs; do
		[ -n "$_ull_idx" ] || continue
		_ull_tmp2=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || {
			rm -f "$_ull_tmp"
			UM_LUCI_ERR=rpcd_config_failed
			return 1
		}
		um_rpcd_rewrite_without_login_index "$_ull_tmp" "$_ull_idx" > "$_ull_tmp2" || {
			rm -f "$_ull_tmp" "$_ull_tmp2"
			UM_LUCI_ERR=rpcd_config_failed
			return 1
		}
		mv "$_ull_tmp2" "$_ull_tmp" || {
			rm -f "$_ull_tmp" "$_ull_tmp2"
			UM_LUCI_ERR=rpcd_config_failed
			return 1
		}
	done
	um_rpcd_atomic_replace "$_ull_tmp" "$USRMANAGE_RPCD_CONFIG" || {
		rm -f "$_ull_tmp"
		UM_LUCI_ERR=rpcd_config_failed
		return 1
	}
	rm -f "$_ull_tmp"
	um_audit luci_revoke "$_ull_name" ok "acl=none" "$_ull_role"
	return 0
}

um_luci_login_remove_owned_best_effort() {
	# Used on del: remove marker+$p$ section even after unregister.
	# Handles multiple matching indexes (issue #98 m6).
	_ull_name=$1
	um_rpcd_config_parsable || {
		um_audit fail "$_ull_name" fail rpcd_config_unparsable
		return 1
	}
	_ull_idxs=$(um_luci_login_ours_index "$_ull_name" 1)
	[ -n "$_ull_idxs" ] || return 0
	_ull_dir=$(dirname "$USRMANAGE_RPCD_CONFIG")
	_ull_tmp=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || return 1
	cp "$USRMANAGE_RPCD_CONFIG" "$_ull_tmp" || {
		rm -f "$_ull_tmp"
		return 1
	}
	# Process in reverse to avoid index shifting.
	_ull_rev_idxs=$(printf '%s' "$_ull_idxs" | sort -nr)
	for _ull_idx in $_ull_rev_idxs; do
		[ -n "$_ull_idx" ] || continue
		_ull_tmp2=$(mktemp "${_ull_dir}/.usrmanage-rpcd.XXXXXX") || {
			rm -f "$_ull_tmp"
			return 1
		}
		um_rpcd_rewrite_without_login_index "$_ull_tmp" "$_ull_idx" > "$_ull_tmp2" || {
			rm -f "$_ull_tmp" "$_ull_tmp2"
			return 1
		}
		mv "$_ull_tmp2" "$_ull_tmp" || {
			rm -f "$_ull_tmp" "$_ull_tmp2"
			return 1
		}
	done
	um_rpcd_atomic_replace "$_ull_tmp" "$USRMANAGE_RPCD_CONFIG" || {
		rm -f "$_ull_tmp"
		return 1
	}
	rm -f "$_ull_tmp"
	return 0
}

um_mut_set_luci_login() {
	# um_mut_set_luci_login <user> <enable|disable|reset>
	# Scope is always derived from UNIX role (no --scope).
	# Wrap rpcd mutations in um_tx_* so a SIGKILL mid multi-index rewrite can
	# restore the prior /etc/config/rpcd from the snapshot (issue #106 L2).
	_ull_name=$1
	_ull_mode=$2
	_ull_scope=$3
	um_mut_require_valid_username "$_ull_name" ""
	um_mut_require_managed "$_ull_name" ""
	um_mut_require_exists "$_ull_name" "" not_found
	if [ -n "$_ull_scope" ]; then
		um_audit denied "$_ull_name" denied luci_scope_role_locked
		um_die "error: luci_scope_role_locked"
	fi
	case "$_ull_mode" in
		enable|1|on)
			if [ "$(um_role_of "$_ull_name")" = "admin" ]; then
				um_rpcd_config_parsable || {
					um_audit denied "$_ull_name" denied rpcd_config_unparsable admin
					um_die "error: rpcd_config_unparsable"
				}
			fi
			um_tx_begin
			um_incomplete_set "luci-login:${_ull_name}:enable"
			um_luci_login_enable_user "$_ull_name" || {
				um_tx_rollback || um_die "error: tx_restore_failed path=$UM_TX_SNAPDIR"
				um_incomplete_clear
				um_audit luci_login "$_ull_name" denied "mode=enable" "$(um_role_of "$_ull_name" 2>/dev/null || printf readonly)"
				um_die "error: ${UM_LUCI_ERR:-luci_login_failed}"
			}
			um_tx_commit
			um_incomplete_clear
			;;
		disable|0|off)
			um_tx_begin
			um_incomplete_set "luci-login:${_ull_name}:disable"
			um_luci_login_disable_user "$_ull_name" || {
				um_tx_rollback || um_die "error: tx_restore_failed path=$UM_TX_SNAPDIR"
				um_incomplete_clear
				um_audit luci_login "$_ull_name" denied "mode=disable" "$(um_role_of "$_ull_name" 2>/dev/null || printf readonly)"
				um_die "error: ${UM_LUCI_ERR:-luci_login_failed}"
			}
			um_tx_commit
			um_incomplete_clear
			;;
		reset)
			um_tx_begin
			um_incomplete_set "luci-login:${_ull_name}:reset"
			um_luci_login_reset_user "$_ull_name" || {
				um_tx_rollback || um_die "error: tx_restore_failed path=$UM_TX_SNAPDIR"
				um_incomplete_clear
				um_audit luci_login "$_ull_name" denied "mode=reset" "$(um_role_of "$_ull_name" 2>/dev/null || printf readonly)"
				um_die "error: ${UM_LUCI_ERR:-luci_login_failed}"
			}
			um_tx_commit
			um_incomplete_clear
			;;
		*)
			um_audit denied "$_ull_name" denied invalid_luci_login_mode
			um_die "error: invalid_luci_login_mode"
			;;
	esac
	_ull_st=$(um_luci_login_state "$_ull_name") || _ull_st=error
	um_audit luci_login "$_ull_name" ok "mode=${_ull_mode}" "$(um_role_of "$_ull_name" 2>/dev/null || printf readonly)"
	if [ "${JSON_OUT:-0}" = "1" ]; then
		printf '{"ok":true,"name":"%s","luci_login":"%s"}\n' \
			"$(printf '%s' "$_ull_name" | um_json_escape)" "$_ull_st"
	else
		printf 'ok: luci_login %s -> %s\n' "$_ull_name" "$_ull_st"
	fi
}

um_luci_login_migrate_observer() {
	# luci-app uci-defaults: rewrite owned logins to role-locked ACL matrices
	# (readonly→diagnostic, admin→full). Ownership gate only
	# (ours_index: marker + $p$user + managed). Never unmarked or root.
	# Caller should hold um_with_lock. Uses um_tx_*.
	um_rpcd_config_parsable || return 1
	um_rpcd_pending_ok || return 1
	[ -f "$USRMANAGE_RPCD_CONFIG" ] || return 0
	_uf=$(um_luci_login_sep)
	_dumpf=$(mktemp "${TMPDIR:-/tmp}/um-obs-mig.XXXXXX") || return 1
	um_rpcd_login_dump > "$_dumpf" || {
		rm -f "$_dumpf"
		return 1
	}
	_changed_users=
	_need_tx=0
	while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw _rs || [ -n "${_i:-}" ]; do
		[ -n "${_i:-}" ] || continue
		[ "$_ru" = "root" ] && continue
		[ "$_rm" = "1" ] || continue
		um_is_managed "$_ru" || continue
		_expect_pass="\$p\$${_ru}"
		[ "$_rp" = "$_expect_pass" ] || continue
		_role=$(um_role_of "$_ru")
		case "$_role" in
			admin|readonly) ;;
			*) continue ;;
		esac
		_scope=$(um_luci_login_normalize_scope "$_rs") || _scope=
		if [ -n "$_scope" ] && um_luci_login_acls_match_role "$_role" "$_rr" "$_rw" "$_scope"; then
			continue
		fi
		_need_tx=1
		case " ${_changed_users} " in
			*" ${_ru} "*) ;;
			*) _changed_users="${_changed_users} ${_ru}" ;;
		esac
	done < "$_dumpf"
	rm -f "$_dumpf"
	[ "$_need_tx" = "1" ] || return 0
	um_tx_begin
	_mig_fail=0
	for _ru in $_changed_users; do
		[ -n "$_ru" ] || continue
		[ "$_ru" = "root" ] && continue
		_idxs=$(um_luci_login_ours_index "$_ru")
		[ -n "$_idxs" ] || continue
		_role=$(um_role_of "$_ru")
		# Never rollback the whole snapshot on a single-user failure: that
		# would restore leftover * / legacy app ACLs (fail-open on upgrade).
		if ! um_luci_login_sync_acls "$_ru" "$_role"; then
			um_luci_login_remove_owned_best_effort "$_ru" || true
			um_session_revoke_user "$_ru" || true
			um_audit fail "$_ru" fail luci_login_migrate_observer "$_role"
			_mig_fail=1
			continue
		fi
		if ! um_session_revoke_user "$_ru"; then
			um_luci_login_remove_owned_best_effort "$_ru" || true
			um_session_revoke_user "$_ru" || true
			um_audit fail "$_ru" fail luci_login_migrate_revoke "$_role"
			_mig_fail=1
			continue
		fi
	done
	um_tx_commit
	[ "$_mig_fail" = "0" ]
}
