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
: "${USRMANAGE_APP_ACL:=luci-app-usrmanage}"

# --- shadow / pending --------------------------------------------------------

um_shadow_hash_usable() {
	# Non-empty, not locked (!/*). Empty hash ⇒ rpcd accepts any password.
	_u=$1
	_sh=$(grep -m1 "^${_u}:" "$USRMANAGE_SHADOW" 2>/dev/null | cut -d: -f2)
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
	# Session ids are 32-char hex keys in the list object.
	_sid_list=$(printf '%s' "$_raw" | grep -oE '"[0-9a-f]{32}"' | tr -d '"' | sort -u)
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

um_session_revoke_required() {
	_u=$1
	um_session_revoke_user "$_u" && return 0
	um_audit fail "$_u" fail session_revoke_unavailable
	um_die "error: session_revoke_unavailable"
}

# --- rpcd config parse / write -----------------------------------------------

# Dump login sections as records: INDEX\x1fUSERNAME\x1fPASSWORD\x1fMARKER\x1fREADS\x1fWRITES
# INDEX is 0-based among login sections only. READS/WRITES are comma-separated.
# Delimiter is ASCII unit separator (\x1f) — safe in $p$ refs and base64 hashes,
# unlike | which can appear in foreign plaintext passwords (issue #98 m3).
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
		printf "%d%s%s%s%s%s%s%s%s%s%s\n", idx, OFS, user, OFS, pass, OFS, marker, OFS, reads, OFS, writes
		user = ""; pass = ""; marker = ""; reads = ""; writes = ""
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
	_raw=$1
	[ -n "$_raw" ] || { printf ''; return 0; }
	printf '%s' "$_raw" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -
}

um_luci_login_expected_reads() {
	printf '%s,%s' "$USRMANAGE_SESSION_ACL" "$USRMANAGE_APP_ACL" | tr ',' '\n' | sort -u | paste -sd, -
}

um_luci_login_expected_writes() {
	# um_luci_login_expected_writes <role>
	if [ "$1" = "admin" ]; then
		printf '%s' "$USRMANAGE_APP_ACL"
	else
		printf ''
	fi
}

um_luci_login_acls_match_role() {
	# um_luci_login_acls_match_role <role> <reads_csv> <writes_csv>
	_role=$1
	_reads=$(um_luci_login_acl_sorted "$2")
	_writes=$(um_luci_login_acl_sorted "$3")
	_ereads=$(um_luci_login_expected_reads)
	_ewrites=$(um_luci_login_expected_writes "$_role")
	[ "$_reads" = "$_ereads" ] || return 1
	[ "$_writes" = "$_ewrites" ] || return 1
	case ",${_reads},${_writes}," in
		*,\*,*) return 1 ;;
	esac
	_old_ifs=$IFS
	IFS=,
	# shellcheck disable=SC2086
	set -- ${_reads} ${_writes}
	IFS=$_old_ifs
	for _g in "$@"; do
		[ "$_g" = "*" ] && return 1
	done
	return 0
}

um_luci_login_classify_row() {
	# args: username password marker reads writes want_user
	# prints owned|foreign|tampered|skip
	_row_user=$1
	_row_pass=$2
	_row_mark=$3
	_row_reads=$4
	_row_writes=$5
	_want=$6
	[ "$_row_user" = "$_want" ] || { printf 'skip'; return 0; }
	_expect_pass="\$p\$${_want}"
	if [ "$_row_mark" = "1" ]; then
		if um_is_managed "$_want" && [ "$_row_pass" = "$_expect_pass" ]; then
			_role=$(um_role_of "$_want")
			if um_luci_login_acls_match_role "$_role" "$_row_reads" "$_row_writes"; then
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

um_luci_login_state() {
	# um_luci_login_state <user> → none|owned|foreign|tampered
	# Returns 1 on internal failure (e.g. mktemp) — callers must treat
	# this as a hard error, never as 'none' (issue #97 M6).
	_ull_name=$1
	_owned=0
	_foreign=0
	_tampered=0
	_stf=$(mktemp "${TMPDIR:-/tmp}/um-luci-st.XXXXXX") || {
		um_audit fail "$_ull_name" fail luci_login_state_tmp
		return 1
	}
	_uf=$(um_luci_login_sep)
	um_rpcd_login_dump | while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw || [ -n "${_i:-}" ]; do
		[ -n "${_i:-}" ] || continue
		_cls=$(um_luci_login_classify_row "$_ru" "$_rp" "$_rm" "$_rr" "$_rw" "$_ull_name")
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
	um_rpcd_login_dump | while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw || [ -n "$_i" ]; do
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
	um_rpcd_login_dump | while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw || [ -n "$_i" ]; do
		[ "$_ru" = "$_ull_name" ] || continue
		[ "$_rm" = "1" ] || continue
		[ "$_rp" = "$_expect_pass" ] || continue
		um_is_managed "$_ull_name" || continue
		um_luci_login_acls_match_role "$_role" "$_rr" "$_rw" || continue
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
	_ull_out=$1
	_ull_uname=$2
	_ull_urole=$3
	{
		printf '\nconfig login\n'
		printf '\toption username '\''%s'\''\n' "$_ull_uname"
		# Literal $p$username for rpcd UNIX-password login (not shell expansion).
		# shellcheck disable=SC2016
		printf '\toption password '\''$p$%s'\''\n' "$_ull_uname"
		printf '\toption usrmanage '\''1'\''\n'
		printf '\tlist read '\''%s'\''\n' "$USRMANAGE_SESSION_ACL"
		printf '\tlist read '\''%s'\''\n' "$USRMANAGE_APP_ACL"
		if [ "$_ull_urole" = "admin" ]; then
			printf '\tlist write '\''%s'\''\n' "$USRMANAGE_APP_ACL"
		fi
	} >> "$_ull_out"
}

um_rpcd_atomic_replace() {
	# Stage beside destination to avoid EXDEV (tmpfs /tmp → overlay /etc).
	_ull_from=$1
	_ull_to=$2
	_ull_todir=$(dirname "$_ull_to")
	_ull_stage=$(mktemp "${_ull_todir}/.usrmanage-rpcd.XXXXXX") || return 1
	cp "$_ull_from" "$_ull_stage" || { rm -f "$_ull_stage"; return 1; }
	chmod 0644 "$_ull_stage" 2>/dev/null || true
	mv "$_ull_stage" "$_ull_to" || { rm -f "$_ull_stage"; return 1; }
	return 0
}

um_luci_login_verify_owned_acls() {
	# After write, confirm ours section has exact role ACL membership.
	_ull_name=$1
	_ull_role=$2
	_ull_idx=$(um_luci_login_ours_index "$_ull_name" | head -n1)
	[ -n "$_ull_idx" ] || return 1
	_uf=$(um_luci_login_sep)
	_row=$(um_rpcd_login_dump | awk -v i="$_ull_idx" -v FS="$_uf" '$1==i {print; exit}')
	_reads=$(printf '%s' "$_row" | awk -v FS="$_uf" '{print $5}')
	_writes=$(printf '%s' "$_row" | awk -v FS="$_uf" '{print $6}')
	um_luci_login_acls_match_role "$_ull_role" "$_reads" "$_writes"
}

um_luci_login_enable_user() {
	# Create owned login for managed user. Caller holds flock.
	# Returns 0/1; sets UM_LUCI_ERR on failure (no um_die — add path must rollback).
	_ull_name=$1
	_ull_role=$(um_role_of "$_ull_name")
	UM_LUCI_ERR=
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
	[ "$_ull_role" = "admin" ] && _ull_acl=rw
	um_audit luci_grant "$_ull_name" ok "acl=${_ull_acl}" "$_ull_role"
	return 0
}

um_luci_login_disable_user() {
	_ull_name=$1
	_ull_role=$(um_role_of "$_ull_name" 2>/dev/null || printf 'readonly')
	UM_LUCI_ERR=
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
	# Works for owned and ACL-drifted (marker+$p$+managed) sections.
	# Handles multiple matching indexes (issue #98 m6).
	_ull_name=$1
	_ull_role=$2
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
	um_rpcd_pending_ok || {
		um_audit denied "$_ull_name" denied rpcd_pending_changes "$_ull_role"
		UM_LUCI_ERR=rpcd_pending_changes
		return 1
	}
	# Find ALL sections with our marker for this user (any password — we reset them).
	_uf=$(um_luci_login_sep)
	_ull_marker_idxs=$(um_rpcd_login_dump | while IFS="$_uf" read -r _i _ru _rp _rm _rr _rw || [ -n "$_i" ]; do
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
	_ull_name=$1
	_ull_mode=$2
	um_mut_require_valid_username "$_ull_name" ""
	um_mut_require_managed "$_ull_name" ""
	um_mut_require_exists "$_ull_name" "" not_found
	case "$_ull_mode" in
		enable|1|on)
			um_incomplete_set "luci-login:${_ull_name}:enable"
			um_luci_login_enable_user "$_ull_name" || {
				um_incomplete_clear
				um_audit luci_login "$_ull_name" denied "mode=enable" "$(um_role_of "$_ull_name" 2>/dev/null || printf readonly)"
				um_die "error: ${UM_LUCI_ERR:-luci_login_failed}"
			}
			um_incomplete_clear
			;;
		disable|0|off)
			um_incomplete_set "luci-login:${_ull_name}:disable"
			um_luci_login_disable_user "$_ull_name" || {
				um_incomplete_clear
				um_audit luci_login "$_ull_name" denied "mode=disable" "$(um_role_of "$_ull_name" 2>/dev/null || printf readonly)"
				um_die "error: ${UM_LUCI_ERR:-luci_login_failed}"
			}
			um_incomplete_clear
			;;
		reset)
			um_incomplete_set "luci-login:${_ull_name}:reset"
			um_luci_login_reset_user "$_ull_name" || {
				um_incomplete_clear
				um_audit luci_login "$_ull_name" denied "mode=reset" "$(um_role_of "$_ull_name" 2>/dev/null || printf readonly)"
				um_die "error: ${UM_LUCI_ERR:-luci_login_failed}"
			}
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
