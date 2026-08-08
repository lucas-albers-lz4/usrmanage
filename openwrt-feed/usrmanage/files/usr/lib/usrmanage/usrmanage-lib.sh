#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Lucas Albers <lucas.b.albers@gmail.com>
#
# Shared library for usrmanage. Sourced by /usr/sbin/usrmanage.
# BusyBox ash-safe: no pipefail, no bashisms. Paths overridable for tests.

# Defaults (overridable via env for unit tests)
: "${USRMANAGE_ETC:=/etc/usrmanage}"
: "${USRMANAGE_REGISTRY:=$USRMANAGE_ETC/users}"
: "${USRMANAGE_AUDIT_DIR:=/var/log/usrmanage}"
: "${USRMANAGE_AUDIT:=$USRMANAGE_AUDIT_DIR/audit.log}"
: "${USRMANAGE_LOCK:=/var/lock/usrmanage.lock}"
: "${USRMANAGE_INCOMPLETE:=$USRMANAGE_ETC/incomplete}"
: "${USRMANAGE_PASSWD:=/etc/passwd}"
: "${USRMANAGE_SHADOW:=/etc/shadow}"
: "${USRMANAGE_GROUP:=/etc/group}"
: "${USRMANAGE_SUDOERS:=/etc/sudoers.d/usrmanage}"
: "${USRMANAGE_UID_FLOOR:=1000}"
: "${USRMANAGE_PASS_MINLEN:=8}"
: "${USRMANAGE_UCI_POLICY:=usrmanage.policy}"
: "${USRMANAGE_AUDIT_MAX_BYTES:=131072}"
: "${USRMANAGE_SHELL:=/bin/ash}"
: "${USRMANAGE_HOME_ROOT:=/home}"
: "${USRMANAGE_SRC:=cli}"
: "${USRMANAGE_ACTOR:=}"
: "${USRMANAGE_DRY_RUN:=0}"

# Effective password policy (populated by um_policy_load)
UM_POL_PRESET=openwrt
UM_POL_MIN_LENGTH=8
UM_POL_REJECT_USERNAME=1
UM_POL_REQUIRE_LOWER=0
UM_POL_REQUIRE_UPPER=0
UM_POL_REQUIRE_DIGIT=0
UM_POL_REQUIRE_SPECIAL=0
UM_POL_FAIL_REASON=

um_json_escape() {
	# Escape for JSON string content (RFC 8259 C0 controls).
	awk 'BEGIN {
		RS = ""; ORS = ""
		for (n = 1; n < 128; n++)
			ord[sprintf("%c", n)] = n
	}
	{
		for (i = 1; i <= length($0); i++) {
			c = substr($0, i, 1)
			if (c == "\\") printf "\\\\"
			else if (c == "\"") printf "\\\""
			else if (c == "\t") printf "\\t"
			else if (c == "\r") printf "\\r"
			else if (c == "\n") printf "\\n"
			else {
				o = ord[c] + 0
				if (o > 0 && o < 32)
					printf "\\u%04x", o
				else if (o == 127)
					printf "\\u007f"
				else
					printf "%s", c
			}
		}
	}'
}

um_err() {
	printf '%s\n' "$*" >&2
}

um_die() {
	_msg=$*
	# LuCI mutators expect structured JSON on stdout (issue #3 M8).
	# Keep stderr for CLI operators; exit 1 for shell scripts. rpcd ignores
	# the CLI exit status and forwards stdout as the ubus reply.
	if [ "${JSON_OUT:-0}" = "1" ]; then
		_err=$_msg
		case "$_err" in
			error:\ *) _err=${_err#error: } ;;
		esac
		printf '{"ok":false,"error":"%s"}\n' "$(printf '%s' "$_err" | um_json_escape)"
	fi
	um_err "$_msg"
	exit 1
}

um_actor_resolve() {
	_raw=
	if [ -n "$USRMANAGE_ACTOR" ]; then
		_raw=$USRMANAGE_ACTOR
	elif [ -n "${USER:-}" ]; then
		_raw=$USER
	else
		_raw=$(id -un 2>/dev/null) || _raw=
	fi
	# Whitelist: block audit field injection (spaces, =, newlines).
	case "$_raw" in
		''|*[!A-Za-z0-9._@-]*)
			printf '%s' "unknown"
			return 0
			;;
	esac
	_alen=${#_raw}
	if [ "$_alen" -lt 1 ] || [ "$_alen" -gt 64 ]; then
		printf '%s' "unknown"
		return 0
	fi
	printf '%s' "$_raw"
}

um_validate_src() {
	case "${USRMANAGE_SRC:-cli}" in
		cli|luci) ;;
		*) USRMANAGE_SRC=cli ;;
	esac
}

# Sanitize a single audit token (no spaces/=/newlines) for log lines.
um_audit_token() {
	_tok=$1
	_fallback=${2:--}
	case "$_tok" in
		''|*[!A-Za-z0-9._@:=-]*)
			printf '%s' "$_fallback"
			return 0
			;;
	esac
	_tlen=${#_tok}
	if [ "$_tlen" -gt 64 ]; then
		printf '%s' "$_fallback"
		return 0
	fi
	printf '%s' "$_tok"
}

um_require_root() {
	[ "$(id -u)" = "0" ] || um_die "error: manage commands require root"
}

um_validate_username() {
	_name=$1
	case "$_name" in
		''|*[!a-z0-9_-]*|[0-9]*|-*)
			return 1
			;;
	esac
	# leading letter or underscore
	case "$_name" in
		[a-z_]* ) ;;
		*) return 1 ;;
	esac
	# length 1..32
	_len=${#_name}
	[ "$_len" -ge 1 ] && [ "$_len" -le 32 ] || return 1
	# deny-list
	case "$_name" in
		root|daemon|ftp|network|nobody|nogroup|admin|ubus|sync)
			return 1
			;;
	esac
	return 0
}

um_validate_role() {
	case "$1" in
		readonly|admin) return 0 ;;
		*) return 1 ;;
	esac
}

um_uci_bool() {
	case "$1" in
		1|true|yes|on) printf '1' ;;
		*) printf '0' ;;
	esac
}

um_policy_defaults_openwrt() {
	UM_POL_PRESET=openwrt
	UM_POL_MIN_LENGTH=8
	UM_POL_REJECT_USERNAME=1
	UM_POL_REQUIRE_LOWER=0
	UM_POL_REQUIRE_UPPER=0
	UM_POL_REQUIRE_DIGIT=0
	UM_POL_REQUIRE_SPECIAL=0
}

um_policy_apply_preset_values() {
	case "$1" in
		openwrt)
			um_policy_defaults_openwrt
			;;
		standard)
			UM_POL_PRESET=standard
			UM_POL_MIN_LENGTH=10
			UM_POL_REJECT_USERNAME=1
			UM_POL_REQUIRE_LOWER=1
			UM_POL_REQUIRE_UPPER=1
			UM_POL_REQUIRE_DIGIT=1
			UM_POL_REQUIRE_SPECIAL=0
			;;
		strict)
			UM_POL_PRESET=strict
			UM_POL_MIN_LENGTH=12
			UM_POL_REJECT_USERNAME=1
			UM_POL_REQUIRE_LOWER=1
			UM_POL_REQUIRE_UPPER=1
			UM_POL_REQUIRE_DIGIT=1
			UM_POL_REQUIRE_SPECIAL=1
			;;
		*)
			return 1
			;;
	esac
	return 0
}

um_policy_detect_preset() {
	if [ "$UM_POL_MIN_LENGTH" = "8" ] && [ "$UM_POL_REJECT_USERNAME" = "1" ] \
		&& [ "$UM_POL_REQUIRE_LOWER" = "0" ] && [ "$UM_POL_REQUIRE_UPPER" = "0" ] \
		&& [ "$UM_POL_REQUIRE_DIGIT" = "0" ] && [ "$UM_POL_REQUIRE_SPECIAL" = "0" ]; then
		printf 'openwrt'
		return 0
	fi
	if [ "$UM_POL_MIN_LENGTH" = "10" ] && [ "$UM_POL_REJECT_USERNAME" = "1" ] \
		&& [ "$UM_POL_REQUIRE_LOWER" = "1" ] && [ "$UM_POL_REQUIRE_UPPER" = "1" ] \
		&& [ "$UM_POL_REQUIRE_DIGIT" = "1" ] && [ "$UM_POL_REQUIRE_SPECIAL" = "0" ]; then
		printf 'standard'
		return 0
	fi
	if [ "$UM_POL_MIN_LENGTH" = "12" ] && [ "$UM_POL_REJECT_USERNAME" = "1" ] \
		&& [ "$UM_POL_REQUIRE_LOWER" = "1" ] && [ "$UM_POL_REQUIRE_UPPER" = "1" ] \
		&& [ "$UM_POL_REQUIRE_DIGIT" = "1" ] && [ "$UM_POL_REQUIRE_SPECIAL" = "1" ]; then
		printf 'strict'
		return 0
	fi
	printf 'custom'
}

um_policy_label() {
	_p=${1:-$UM_POL_PRESET}
	case "$_p" in
		openwrt) printf 'OpenWrt' ;;
		standard) printf 'Standard' ;;
		strict) printf 'Strict' ;;
		*) printf 'Custom' ;;
	esac
}

um_policy_load() {
	um_policy_defaults_openwrt
	_ml=
	_ru=
	_rl=
	_ru2=
	_rd=
	_rs=
	if command -v uci >/dev/null 2>&1; then
		_ml=$(uci -q get usrmanage.policy.min_length 2>/dev/null) || _ml=
		_ru=$(uci -q get usrmanage.policy.reject_username 2>/dev/null) || _ru=
		_rl=$(uci -q get usrmanage.policy.require_lower 2>/dev/null) || _rl=
		_ru2=$(uci -q get usrmanage.policy.require_upper 2>/dev/null) || _ru2=
		_rd=$(uci -q get usrmanage.policy.require_digit 2>/dev/null) || _rd=
		_rs=$(uci -q get usrmanage.policy.require_special 2>/dev/null) || _rs=
	fi
	[ -n "$_ml" ] && UM_POL_MIN_LENGTH=$_ml
	[ -n "$_ru" ] && UM_POL_REJECT_USERNAME=$(um_uci_bool "$_ru")
	[ -n "$_rl" ] && UM_POL_REQUIRE_LOWER=$(um_uci_bool "$_rl")
	[ -n "$_ru2" ] && UM_POL_REQUIRE_UPPER=$(um_uci_bool "$_ru2")
	[ -n "$_rd" ] && UM_POL_REQUIRE_DIGIT=$(um_uci_bool "$_rd")
	[ -n "$_rs" ] && UM_POL_REQUIRE_SPECIAL=$(um_uci_bool "$_rs")
	case "$UM_POL_MIN_LENGTH" in
		8|10|12|14|16) ;;
		*) UM_POL_MIN_LENGTH=8 ;;
	esac
	UM_POL_PRESET=$(um_policy_detect_preset)
	USRMANAGE_PASS_MINLEN=$UM_POL_MIN_LENGTH
}

um_policy_save() {
	command -v uci >/dev/null 2>&1 || return 1
	uci -q set usrmanage.policy=usrmanage
	uci -q set usrmanage.policy.preset="$UM_POL_PRESET"
	uci -q set usrmanage.policy.min_length="$UM_POL_MIN_LENGTH"
	uci -q set usrmanage.policy.reject_username="$UM_POL_REJECT_USERNAME"
	uci -q set usrmanage.policy.require_lower="$UM_POL_REQUIRE_LOWER"
	uci -q set usrmanage.policy.require_upper="$UM_POL_REQUIRE_UPPER"
	uci -q set usrmanage.policy.require_digit="$UM_POL_REQUIRE_DIGIT"
	uci -q set usrmanage.policy.require_special="$UM_POL_REQUIRE_SPECIAL"
	uci -q commit usrmanage
}

um_policy_bool_json() {
	[ "$1" = "1" ] && printf 'true' || printf 'false'
}

um_policy_set_fields() {
	# preset min reject lower upper digit special
	_preset=$1
	_min=$2
	_rej=$3
	_low=$4
	_up=$5
	_dig=$6
	_spe=$7
	case "$_preset" in
		openwrt|standard|strict)
			um_policy_apply_preset_values "$_preset" || return 1
			;;
		custom)
			case "$_min" in
				8|10|12|14|16) UM_POL_MIN_LENGTH=$_min ;;
				*) um_err "error: invalid min_length"; return 1 ;;
			esac
			UM_POL_REJECT_USERNAME=$(um_uci_bool "${_rej:-0}")
			UM_POL_REQUIRE_LOWER=$(um_uci_bool "${_low:-0}")
			UM_POL_REQUIRE_UPPER=$(um_uci_bool "${_up:-0}")
			UM_POL_REQUIRE_DIGIT=$(um_uci_bool "${_dig:-0}")
			UM_POL_REQUIRE_SPECIAL=$(um_uci_bool "${_spe:-0}")
			UM_POL_PRESET=$(um_policy_detect_preset)
			;;
		*)
			um_err "error: invalid preset"
			return 1
			;;
	esac
	USRMANAGE_PASS_MINLEN=$UM_POL_MIN_LENGTH
	return 0
}

um_policy_json_name() {
	um_policy_load
	_lab=$(um_policy_label "$UM_POL_PRESET")
	_pe=$(printf '%s' "$UM_POL_PRESET" | um_json_escape)
	_le=$(printf '%s' "$_lab" | um_json_escape)
	printf '{"preset":"%s","label":"%s"}\n' "$_pe" "$_le"
}

um_policy_json_full() {
	um_policy_load
	_lab=$(um_policy_label "$UM_POL_PRESET")
	_pe=$(printf '%s' "$UM_POL_PRESET" | um_json_escape)
	_le=$(printf '%s' "$_lab" | um_json_escape)
	printf '{"preset":"%s","label":"%s","min_length":%s,"reject_username":%s,"require_lower":%s,"require_upper":%s,"require_digit":%s,"require_special":%s}\n' \
		"$_pe" "$_le" "$UM_POL_MIN_LENGTH" \
		"$(um_policy_bool_json "$UM_POL_REJECT_USERNAME")" \
		"$(um_policy_bool_json "$UM_POL_REQUIRE_LOWER")" \
		"$(um_policy_bool_json "$UM_POL_REQUIRE_UPPER")" \
		"$(um_policy_bool_json "$UM_POL_REQUIRE_DIGIT")" \
		"$(um_policy_bool_json "$UM_POL_REQUIRE_SPECIAL")"
}

um_validate_password() {
	_user=$1
	_pass=$2
	UM_POL_FAIL_REASON=
	um_policy_load
	[ -n "$_pass" ] || {
		UM_POL_FAIL_REASON=empty
		return 1
	}
	_plen=${#_pass}
	if [ "$_plen" -lt "$UM_POL_MIN_LENGTH" ]; then
		UM_POL_FAIL_REASON=min_length
		return 1
	fi
	if [ "$UM_POL_REJECT_USERNAME" = "1" ] && [ "$_pass" = "$_user" ]; then
		UM_POL_FAIL_REASON=reject_username
		return 1
	fi
	if [ "$UM_POL_REQUIRE_LOWER" = "1" ]; then
		case "$_pass" in
			*[a-z]*) ;;
			*) UM_POL_FAIL_REASON=require_lower; return 1 ;;
		esac
	fi
	if [ "$UM_POL_REQUIRE_UPPER" = "1" ]; then
		case "$_pass" in
			*[A-Z]*) ;;
			*) UM_POL_FAIL_REASON=require_upper; return 1 ;;
		esac
	fi
	if [ "$UM_POL_REQUIRE_DIGIT" = "1" ]; then
		case "$_pass" in
			*[0-9]*) ;;
			*) UM_POL_FAIL_REASON=require_digit; return 1 ;;
		esac
	fi
	if [ "$UM_POL_REQUIRE_SPECIAL" = "1" ]; then
		_stripped=$(printf '%s' "$_pass" | tr -d 'A-Za-z0-9')
		if [ -z "$_stripped" ]; then
			UM_POL_FAIL_REASON=require_special
			return 1
		fi
	fi
	return 0
}

um_ensure_dirs() {
	# um_ensure_dirs [strict] — soft by default; strict hard-fails (issue #3 M4).
	_strict=0
	[ "${1:-}" = "strict" ] && _strict=1
	if [ "$_strict" = "1" ]; then
		mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" \
			|| um_die "error: dirs_failed"
		[ -f "$USRMANAGE_REGISTRY" ] || touch "$USRMANAGE_REGISTRY" || um_die "error: dirs_failed"
		[ -f "$USRMANAGE_AUDIT" ] || touch "$USRMANAGE_AUDIT" || um_die "error: dirs_failed"
	else
		mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" 2>/dev/null || true
		[ -f "$USRMANAGE_REGISTRY" ] || touch "$USRMANAGE_REGISTRY"
		[ -f "$USRMANAGE_AUDIT" ] || touch "$USRMANAGE_AUDIT"
	fi
	chmod 0750 "$USRMANAGE_AUDIT_DIR" 2>/dev/null || true
	chmod 0640 "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT" 2>/dev/null || true
}

um_ensure_dirs_strict() { um_ensure_dirs strict; }

um_is_managed() {
	_u=$1
	[ -f "$USRMANAGE_REGISTRY" ] || return 1
	grep -qx "$_u" "$USRMANAGE_REGISTRY" 2>/dev/null
}

um_registry_add() {
	_u=$1
	um_is_managed "$_u" && return 0
	printf '%s\n' "$_u" >> "$USRMANAGE_REGISTRY" || return 1
	chmod 0640 "$USRMANAGE_REGISTRY" 2>/dev/null || true
	chown 0:0 "$USRMANAGE_REGISTRY" 2>/dev/null || true
}

um_registry_del() {
	# D3: umask 077 temp, chmod 0640, chown 0:0, then mv (match um_atomic_edit).
	_u=$1
	_tmp="${USRMANAGE_REGISTRY}.tmp.$$"
	if [ -f "$USRMANAGE_REGISTRY" ]; then
		(
			umask 077
			grep -vx "$_u" "$USRMANAGE_REGISTRY" > "$_tmp" 2>/dev/null || : > "$_tmp"
		) || {
			rm -f "$_tmp"
			return 1
		}
		chmod 0640 "$_tmp" || {
			rm -f "$_tmp"
			return 1
		}
		chown 0:0 "$_tmp" 2>/dev/null || true
		mv "$_tmp" "$USRMANAGE_REGISTRY" || {
			rm -f "$_tmp"
			return 1
		}
	fi
}

um_passwd_line() {
	_u=$1
	grep -m1 "^${_u}:" "$USRMANAGE_PASSWD" 2>/dev/null
}

um_user_exists() {
	um_passwd_line "$1" >/dev/null
}

um_passwd_field() {
	# um_passwd_field <user> <field> — 3=uid 4=gid 6=home 7=shell
	_line=$(um_passwd_line "$1") || return 1
	printf '%s' "$_line" | cut -d: -f"$2"
}

um_user_uid() { um_passwd_field "$1" 3; }
um_user_gid() { um_passwd_field "$1" 4; }
um_user_home() { um_passwd_field "$1" 6; }
um_user_shell() { um_passwd_field "$1" 7; }

um_user_locked() {
	_u=$1
	_sh=$(grep -m1 "^${_u}:" "$USRMANAGE_SHADOW" 2>/dev/null | cut -d: -f2)
	case "$_sh" in
		'!'*|'*'*) return 0 ;;
		*) return 1 ;;
	esac
}

um_in_wheel() {
	_u=$1
	_line=$(grep -m1 '^wheel:' "$USRMANAGE_GROUP" 2>/dev/null) || return 1
	_members=$(printf '%s' "$_line" | cut -d: -f4)
	case ",${_members}," in
		*",${_u},"*) return 0 ;;
		*) return 1 ;;
	esac
}

um_role_of() {
	_u=$1
	if um_in_wheel "$_u"; then
		printf '%s' "admin"
	else
		printf '%s' "readonly"
	fi
}

um_count_managed_admins() {
	_n=0
	[ -f "$USRMANAGE_REGISTRY" ] || { printf '%s' "0"; return 0; }
	while IFS= read -r _u || [ -n "$_u" ]; do
		case "$_u" in
			''|\#*) continue ;;
		esac
		um_user_exists "$_u" || continue
		if um_in_wheel "$_u"; then
			_n=$((_n + 1))
		fi
	done < "$USRMANAGE_REGISTRY"
	printf '%s' "$_n"
}

um_audit_rotate_if_needed() {
	[ -f "$USRMANAGE_AUDIT" ] || return 0
	_sz=$(wc -c < "$USRMANAGE_AUDIT" 2>/dev/null | tr -d ' ')
	[ -n "$_sz" ] || return 0
	if [ "$_sz" -gt "$USRMANAGE_AUDIT_MAX_BYTES" ]; then
		_keep=$((USRMANAGE_AUDIT_MAX_BYTES / 2))
		tail -c "$_keep" "$USRMANAGE_AUDIT" > "${USRMANAGE_AUDIT}.1" 2>/dev/null && \
			mv "${USRMANAGE_AUDIT}.1" "$USRMANAGE_AUDIT"
		chmod 0640 "$USRMANAGE_AUDIT" 2>/dev/null || true
	fi
}

um_audit() {
	# um_audit <action> <user> <result> [reason] [role]
	_action=$(um_audit_token "$1" "unknown")
	_auser=$(um_audit_token "$2" "invalid")
	_result=$(um_audit_token "$3" "fail")
	_reason=
	[ -n "${4:-}" ] && _reason=$(um_audit_token "$4" "")
	_role=
	[ -n "${5:-}" ] && _role=$(um_audit_token "$5" "")
	um_validate_src
	_actor=$(um_actor_resolve)
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
	_line="${_ts} ${_action} user=${_auser}"
	[ -n "$_role" ] && _line="${_line} role=${_role}"
	_line="${_line} actor=${_actor} src=${USRMANAGE_SRC} result=${_result}"
	[ -n "$_reason" ] && _line="${_line} reason=${_reason}"
	um_ensure_dirs
	um_audit_rotate_if_needed
	printf '%s\n' "$_line" >> "$USRMANAGE_AUDIT"
	logger -t usrmanage -- "$_line" 2>/dev/null || true
}

um_incomplete_set() {
	printf '%s\n' "$1" > "$USRMANAGE_INCOMPLETE"
}

um_incomplete_clear() {
	rm -f "$USRMANAGE_INCOMPLETE"
}

# Multi-file transaction snapshots (shadow-free create/delete). Restored on
# EXIT unless um_tx_commit runs. Paths honor USRMANAGE_*.
# EXIT hook is installed once. BusyBox ash/dash cannot reliably chain a prior
# EXIT trap via $(trap | grep) capture (empty inside command substitution), so
# we do not attempt chaining. The shipped CLI installs no prior EXIT trap;
# the hook alone is the safety net for uncommitted transactions.
UM_TX_SNAPDIR=
UM_TX_COMMITTED=0
UM_TX_ACTIVE=0

um_tx_exit_hook() {
	_tx_rc=$?
	if [ "${UM_TX_ACTIVE:-0}" = "1" ] && [ "${UM_TX_COMMITTED:-0}" != "1" ]; then
		um_tx_rollback || _tx_rc=1
	fi
	[ "$_tx_rc" -eq 0 ] || exit "$_tx_rc"
}

um_tx_ensure_exit_hook() {
	# Always install in this shell — EXIT traps are not inherited across
	# subshells, so a once-only flag would skip install after the parent ran.
	trap 'um_tx_exit_hook' EXIT
}

um_tx_snap_one() {
	_tx_src=$1
	_tx_label=$2
	[ -n "$UM_TX_SNAPDIR" ] || return 1
	if [ -f "$_tx_src" ]; then
		cp "$_tx_src" "${UM_TX_SNAPDIR}/${_tx_label}" || return 1
	else
		printf 'missing\n' > "${UM_TX_SNAPDIR}/${_tx_label}.missing"
	fi
	return 0
}

um_tx_begin() {
	# Snapshot passwd/shadow/group/registry for rollback on failure.
	# Install EXIT hook + ACTIVE before the snap loop so a mid-begin
	# um_die still cleans the snapdir (via rollback incomplete-begin path).
	if [ "${UM_TX_ACTIVE:-0}" = "1" ]; then
		um_die "error: tx_nested"
	fi
	UM_TX_COMMITTED=0
	UM_TX_SNAPDIR=$(mktemp -d "${TMPDIR:-/tmp}/usrmanage-tx.XXXXXX") \
		|| um_die "error: tx_snapshot_failed"
	um_tx_ensure_exit_hook
	UM_TX_ACTIVE=1
	um_tx_snap_one "$USRMANAGE_PASSWD" passwd || um_die "error: tx_snapshot_failed"
	um_tx_snap_one "$USRMANAGE_SHADOW" shadow || um_die "error: tx_snapshot_failed"
	um_tx_snap_one "$USRMANAGE_GROUP" group || um_die "error: tx_snapshot_failed"
	um_tx_snap_one "$USRMANAGE_REGISTRY" registry || um_die "error: tx_snapshot_failed"
	# Marker: rollback treats missing .complete as aborted begin (discard snapdir).
	touch "${UM_TX_SNAPDIR}/.complete" || um_die "error: tx_snapshot_failed"
}

um_tx_restore_one() {
	_tx_dst=$1
	_tx_label=$2
	[ -n "$UM_TX_SNAPDIR" ] || return 1
	if [ -f "${UM_TX_SNAPDIR}/${_tx_label}.missing" ]; then
		rm -f "$_tx_dst"
		return 0
	fi
	[ -f "${UM_TX_SNAPDIR}/${_tx_label}" ] || return 1
	cp "${UM_TX_SNAPDIR}/${_tx_label}" "$_tx_dst" || return 1
	case "$_tx_label" in
		shadow) chmod 0600 "$_tx_dst" 2>/dev/null || true ;;
		passwd|group) chmod 0644 "$_tx_dst" 2>/dev/null || true ;;
		registry) chmod 0640 "$_tx_dst" 2>/dev/null || true ;;
	esac
	chown 0:0 "$_tx_dst" 2>/dev/null || true
	return 0
}

um_tx_rollback() {
	[ "${UM_TX_COMMITTED:-0}" = "1" ] && return 0
	[ -n "${UM_TX_SNAPDIR:-}" ] || {
		UM_TX_ACTIVE=0
		return 0
	}
	# Aborted begin (never reached .complete): live files untouched; discard.
	if [ ! -f "${UM_TX_SNAPDIR}/.complete" ]; then
		UM_TX_ACTIVE=0
		rm -rf "$UM_TX_SNAPDIR"
		UM_TX_SNAPDIR=
		return 0
	fi
	_ok=1
	um_tx_restore_one "$USRMANAGE_PASSWD" passwd || _ok=0
	um_tx_restore_one "$USRMANAGE_SHADOW" shadow || _ok=0
	um_tx_restore_one "$USRMANAGE_GROUP" group || _ok=0
	um_tx_restore_one "$USRMANAGE_REGISTRY" registry || _ok=0
	UM_TX_ACTIVE=0
	if [ "$_ok" != "1" ]; then
		# Keep snapdir for CLI/doctor recovery (tmpfs until reboot).
		# Callers must pass path= into um_die so JSON/LuCI see it (stdout);
		# um_err covers CLI stderr. Doctor scans for orphaned usrmanage-tx.*.
		um_err "error: tx_restore_failed path=$UM_TX_SNAPDIR"
		return 1
	fi
	rm -rf "$UM_TX_SNAPDIR"
	UM_TX_SNAPDIR=
	return 0
}

um_tx_commit() {
	UM_TX_COMMITTED=1
	UM_TX_ACTIVE=0
	[ -n "${UM_TX_SNAPDIR:-}" ] && rm -rf "$UM_TX_SNAPDIR"
	UM_TX_SNAPDIR=
}

# Atomic awk rewrite: umask 077 temp, fixed mode + chown 0:0, then mv (D3).
# Usage: um_atomic_edit <path> <octal_mode> [awk args...]
# Remaining args are passed to awk; <path> is appended as the input file.
um_atomic_edit() {
	_path=$1
	_mode=$2
	shift 2
	_tmp="${_path}.tmp.$$"
	(
		umask 077
		awk "$@" "$_path" > "$_tmp"
	) || {
		rm -f "$_tmp"
		return 1
	}
	chmod "$_mode" "$_tmp" || {
		rm -f "$_tmp"
		return 1
	}
	chown 0:0 "$_tmp" 2>/dev/null || true
	mv "$_tmp" "$_path" || {
		rm -f "$_tmp"
		return 1
	}
	return 0
}

# Smallest free uid in USRMANAGE_UID_FLOOR..60000 whose paired gid is free (D4).
# Prints "uid gid" on success. Audits and returns 1 on range exhaustion.
um_id_taken() {
	# um_id_taken <file> <id>
	awk -F: -v id="$2" '$3 == id { found = 1; exit } END { exit !found }' "$1" 2>/dev/null
}

um_uid_taken() { um_id_taken "$USRMANAGE_PASSWD" "$1"; }
um_gid_taken() { um_id_taken "$USRMANAGE_GROUP" "$1"; }

um_alloc_ids() {
	_uid=$USRMANAGE_UID_FLOOR
	while [ "$_uid" -le 60000 ]; do
		if ! um_uid_taken "$_uid" && ! um_gid_taken "$_uid"; then
			printf '%s %s\n' "$_uid" "$_uid"
			return 0
		fi
		_uid=$((_uid + 1))
	done
	um_audit "denied" "-" "fail" "uid_range_exhausted" || true
	um_err "error: uid_range_exhausted"
	return 1
}

um_with_lock() {
	# um_with_lock <shell function name> [args...]
	# Requires flock (BusyBox or util-linux). No mkdir fallback — that path
	# broke set -e and left stale locks on um_die (issue #3 C3/C4).
	# BusyBox flock on OpenWrt 24.10/25.12 has no -w timeout (only -sxun);
	# a stuck holder therefore blocks concurrent callers indefinitely.
	um_ensure_dirs_strict
	command -v flock >/dev/null 2>&1 || um_die "error: flock_required"
	_fn=$1
	shift
	(
		flock -x 9 || exit 1
		"$_fn" "$@"
	) 9>"$USRMANAGE_LOCK"
}

um_ensure_wheel_group() {
	if grep -q '^wheel:' "$USRMANAGE_GROUP" 2>/dev/null; then
		return 0
	fi
	if [ "$USRMANAGE_DRY_RUN" = "1" ]; then
		return 0
	fi
	if command -v groupadd >/dev/null 2>&1; then
		groupadd -r wheel 2>/dev/null || groupadd wheel || return 1
	else
		_gid=100
		while grep -q ":${_gid}:" "$USRMANAGE_GROUP" 2>/dev/null; do
			_gid=$((_gid + 1))
		done
		echo "wheel:x:${_gid}:" >> "$USRMANAGE_GROUP"
	fi
}

um_wheel_add_user() {
	_u=$1
	um_ensure_wheel_group || return 1
	if um_in_wheel "$_u"; then
		return 0
	fi
	if command -v gpasswd >/dev/null 2>&1; then
		gpasswd -a "$_u" wheel >/dev/null 2>&1 && um_in_wheel "$_u" && return 0
	fi
	if command -v usermod >/dev/null 2>&1; then
		usermod -a -G wheel "$_u" >/dev/null 2>&1 && um_in_wheel "$_u" && return 0
	fi
	# Manual append to wheel members (atomic replace, D3 modes)
	# shellcheck disable=SC2016
	if um_atomic_edit "$USRMANAGE_GROUP" 0644 -v u="$_u" -F: '
		BEGIN { OFS=":" }
		$1=="wheel" {
			if ($4 == "") $4 = u
			else if (index("," $4 ",", "," u ",") == 0) $4 = $4 "," u
		}
		{ print }
	'; then
		um_in_wheel "$_u"
		return $?
	fi
	return 1
}

um_wheel_del_user() {
	_u=$1
	if ! um_in_wheel "$_u"; then
		return 0
	fi
	if command -v gpasswd >/dev/null 2>&1; then
		gpasswd -d "$_u" wheel >/dev/null 2>&1 || true
		if ! um_in_wheel "$_u"; then
			return 0
		fi
	fi
	# shellcheck disable=SC2016
	if um_atomic_edit "$USRMANAGE_GROUP" 0644 -v u="$_u" -F: '
		BEGIN { OFS=":" }
		$1=="wheel" {
			n = split($4, a, ",")
			out = ""
			for (i = 1; i <= n; i++) {
				if (a[i] == "" || a[i] == u) continue
				if (out == "") out = a[i]
				else out = out "," a[i]
			}
			$4 = out
		}
		{ print }
	'; then
		if um_in_wheel "$_u"; then
			return 1
		fi
		return 0
	fi
	return 1
}

um_password_write() {
	# um_password_write <user> <password> — chpasswd preferred; busybox passwd -a sha512
	_u=$1
	_pw=$2
	# Prefer chpasswd (stdin: user:pass) — avoids shell echo | passwd
	if command -v chpasswd >/dev/null 2>&1; then
		printf '%s:%s\n' "$_u" "$_pw" | chpasswd
		_rc=$?
		_pw=
		return $_rc
	fi
	# BusyBox: pipe new+retype; pin sha512 crypt ($6$) via -a (D6).
	printf '%s\n%s\n' "$_pw" "$_pw" | passwd -a sha512 "$_u" >/dev/null 2>&1
	_rc=$?
	_pw=
	return $_rc
}

um_set_password_from_fd() {
	_u=$1
	_fd=$2
	# Read password once from FD (no echo to logs)
	_pass=
	# shellcheck disable=SC2039
	IFS= read -r _pass <&"$_fd" || true
	um_validate_password "$_u" "$_pass" || {
		_pass=
		return 1
	}
	if [ "$USRMANAGE_DRY_RUN" = "1" ]; then
		_pass=
		return 0
	fi
	um_password_write "$_u" "$_pass"
	_rc=$?
	_pass=
	return $_rc
}

um_set_password_prompt() {
	_u=$1
	if [ ! -t 0 ]; then
		um_err "error: no TTY; use --password-fd"
		return 1
	fi
	printf 'New password: ' >&2
	stty -echo 2>/dev/null || true
	IFS= read -r _p1 || true
	stty echo 2>/dev/null || true
	printf '\nConfirm password: ' >&2
	stty -echo 2>/dev/null || true
	IFS= read -r _p2 || true
	stty echo 2>/dev/null || true
	printf '\n' >&2
	[ "$_p1" = "$_p2" ] || {
		_p1=
		_p2=
		um_err "error: passwords do not match"
		return 1
	}
	um_validate_password "$_u" "$_p1" || {
		_p1=
		_p2=
		um_err "error: password policy failed (${UM_POL_FAIL_REASON:-policy})"
		return 1
	}
	_p2=
	if [ "$USRMANAGE_DRY_RUN" = "1" ]; then
		_p1=
		return 0
	fi
	um_password_write "$_u" "$_p1"
	_rc=$?
	_p1=
	return $_rc
}

um_lock_account() {
	_u=$1
	if [ "$USRMANAGE_DRY_RUN" = "1" ]; then
		return 0
	fi
	if command -v passwd >/dev/null 2>&1; then
		passwd -l "$_u" >/dev/null 2>&1 && return 0
	fi
	# Already locked (! or * prefix) counts as success when passwd -l fails.
	if um_user_locked "$_u"; then
		return 0
	fi
	if command -v usermod >/dev/null 2>&1; then
		usermod -L "$_u" >/dev/null 2>&1 && return 0
	fi
	# Manual lock: prefix hash with ! while preserving aging fields (D2).
	# shellcheck disable=SC2016
	um_atomic_edit "$USRMANAGE_SHADOW" 0600 -v u="$_u" -F: '
		BEGIN { OFS=":" }
		$1 == u {
			if (substr($2, 1, 1) != "!" && substr($2, 1, 1) != "*")
				$2 = "!" $2
		}
		{ print }
	' && um_user_locked "$_u"
}

um_kill_user_procs() {
	_u=$1
	if [ "$USRMANAGE_DRY_RUN" = "1" ]; then
		return 0
	fi
	# Best-effort; BusyBox may lack pkill -u
	if command -v pkill >/dev/null 2>&1; then
		pkill -u "$_u" 2>/dev/null || true
		sleep 1
		pkill -9 -u "$_u" 2>/dev/null || true
		return 0
	fi
	_uid=$(um_user_uid "$_u") || return 0
	# Fallback: scan /proc
	for _d in /proc/[0-9]*; do
		[ -r "$_d/status" ] || continue
		_pu=$(awk '/^Uid:/{print $2; exit}' "$_d/status" 2>/dev/null) || continue
		if [ "$_pu" = "$_uid" ]; then
			_pid=${_d#/proc/}
			kill "$_pid" 2>/dev/null || true
		fi
	done
	sleep 1
	for _d in /proc/[0-9]*; do
		[ -r "$_d/status" ] || continue
		_pu=$(awk '/^Uid:/{print $2; exit}' "$_d/status" 2>/dev/null) || continue
		if [ "$_pu" = "$_uid" ]; then
			_pid=${_d#/proc/}
			kill -9 "$_pid" 2>/dev/null || true
		fi
	done
	return 0
}

# --- BusyBox / manual account mutation fallbacks (shadow-free) ---

um_passwd_entry_add() {
	_u=$1
	_uid=$2
	_gid=$3
	_home=$4
	_shell=$5
	um_user_exists "$_u" && return 0
	printf '%s:x:%s:%s:%s:%s:%s\n' "$_u" "$_uid" "$_gid" "$_u" "$_home" "$_shell" \
		>> "$USRMANAGE_PASSWD" || return 1
	chmod 0644 "$USRMANAGE_PASSWD" 2>/dev/null || true
	chown 0:0 "$USRMANAGE_PASSWD" 2>/dev/null || true
	return 0
}

um_group_entry_add() {
	_name=$1
	_gid=$2
	_line=$(grep -m1 "^${_name}:" "$USRMANAGE_GROUP" 2>/dev/null) || true
	if [ -n "$_line" ]; then
		_egid=$(printf '%s' "$_line" | cut -d: -f3)
		if [ "$_egid" != "$_gid" ]; then
			um_err "error: group_gid_mismatch"
			return 1
		fi
		return 0
	fi
	printf '%s:x:%s:\n' "$_name" "$_gid" >> "$USRMANAGE_GROUP" || return 1
	chmod 0644 "$USRMANAGE_GROUP" 2>/dev/null || true
	chown 0:0 "$USRMANAGE_GROUP" 2>/dev/null || true
	return 0
}

um_shadow_entry_add() {
	# D2: new-user placeholder is locked "!"; preserve aging defaults.
	_u=$1
	if grep -q "^${_u}:" "$USRMANAGE_SHADOW" 2>/dev/null; then
		return 0
	fi
	# shadow(5): name:pass:lastchg:min:max:warn:inactive:expire
	# Empty lastchg; min=0 max=99999 warn=7 (mirrors stock root:::0:99999:7:::).
	printf '%s:!::0:99999:7:::\n' "$_u" >> "$USRMANAGE_SHADOW" || return 1
	chmod 0600 "$USRMANAGE_SHADOW" 2>/dev/null || true
	chown 0:0 "$USRMANAGE_SHADOW" 2>/dev/null || true
	return 0
}

um_home_create() {
	_u=$1
	_uid=$2
	_gid=$3
	_home=$4
	# Refuse symlinks (matches um_home_remove) — never chmod/chown through them.
	if [ -L "$_home" ]; then
		um_err "error: home_is_symlink"
		return 1
	fi
	# Match useradd -m: do not take over an existing path (incl. root-owned).
	if [ -e "$_home" ]; then
		um_err "error: home_exists"
		return 1
	fi
	mkdir -p "$_home" || return 1
	if [ -L "$_home" ]; then
		um_err "error: home_is_symlink"
		return 1
	fi
	chmod 0750 "$_home" || return 1
	if ! chown "${_uid}:${_gid}" "$_home" 2>/dev/null; then
		# Root must own the home for the new UID; non-root host tests are best-effort.
		if [ "$(id -u 2>/dev/null)" = "0" ]; then
			um_err "error: home_chown_failed"
			return 1
		fi
	fi
	return 0
}

um_passwd_entry_del() {
	_u=$1
	# shellcheck disable=SC2016
	um_atomic_edit "$USRMANAGE_PASSWD" 0644 -v u="$_u" -F: '$1 != u { print }'
}

um_shadow_entry_del() {
	_u=$1
	# shellcheck disable=SC2016
	um_atomic_edit "$USRMANAGE_SHADOW" 0600 -v u="$_u" -F: '$1 != u { print }'
}

um_group_entry_del() {
	# Remove private group named after user; bail if other members present.
	_u=$1
	_line=$(grep -m1 "^${_u}:" "$USRMANAGE_GROUP" 2>/dev/null) || return 0
	_members=$(printf '%s' "$_line" | cut -d: -f4)
	_others=
	if [ -n "$_members" ]; then
		_others=$(printf '%s' "$_members" | tr ',' '\n' | grep -vx '' | grep -vx "$_u" || true)
	fi
	if [ -n "$_others" ]; then
		um_audit "denied" "$_u" "fail" "group_has_members" || true
		um_err "error: group_has_members"
		return 1
	fi
	# Strip user from other groups' member lists, then drop private group.
	# shellcheck disable=SC2016
	um_atomic_edit "$USRMANAGE_GROUP" 0644 -v u="$_u" -F: '
		BEGIN { OFS=":" }
		$1 == u { next }
		{
			n = split($4, a, ",")
			out = ""
			for (i = 1; i <= n; i++) {
				if (a[i] == "" || a[i] == u) continue
				if (out == "") out = a[i]
				else out = out "," a[i]
			}
			$4 = out
			print
		}
	'
}

um_home_remove() {
	_home=$1
	[ -e "$_home" ] || return 0
	# Refuse symlinks and non-directories
	if [ -L "$_home" ] || [ ! -d "$_home" ]; then
		um_err "error: home_not_directory"
		return 1
	fi
	rm -rf "$_home" || return 1
	return 0
}

um_delete_account() {
	_u=$1
	_purge=$2
	if [ "$USRMANAGE_DRY_RUN" = "1" ]; then
		return 0
	fi
	_home=$(um_user_home "$_u" 2>/dev/null) || _home="${USRMANAGE_HOME_ROOT}/${_u}"
	if command -v userdel >/dev/null 2>&1; then
		if [ "$_purge" = "1" ]; then
			userdel -r "$_u" >/dev/null 2>&1 && return 0
		else
			userdel "$_u" >/dev/null 2>&1 && return 0
		fi
	fi
	if command -v deluser >/dev/null 2>&1; then
		if [ "$_purge" = "1" ]; then
			deluser --remove-home "$_u" >/dev/null 2>&1 && return 0
		else
			deluser "$_u" >/dev/null 2>&1 && return 0
		fi
	fi
	# Manual fallback
	um_passwd_entry_del "$_u" || return 1
	um_shadow_entry_del "$_u" || return 1
	um_group_entry_del "$_u" || return 1
	if [ "$_purge" = "1" ]; then
		um_home_remove "$_home" || return 1
	fi
	return 0
}

um_create_user() {
	_u=$1
	_role=$2
	if [ "$USRMANAGE_DRY_RUN" = "1" ]; then
		return 0
	fi
	_home="${USRMANAGE_HOME_ROOT}/${_u}"
	if command -v useradd >/dev/null 2>&1; then
		useradd -m -d "$_home" -s "$USRMANAGE_SHELL" "$_u" || return 1
	elif command -v adduser >/dev/null 2>&1; then
		# BusyBox adduser non-interactive (absent on stock OpenWrt)
		adduser -D -h "$_home" -s "$USRMANAGE_SHELL" "$_u" || return 1
	else
		# Manual create: private group gid=uid (D1), locked shadow placeholder (D2)
		_ids=$(um_alloc_ids) || return 1
		_uid=${_ids%% *}
		_gid=${_ids##* }
		um_group_entry_add "$_u" "$_gid" || return 1
		um_passwd_entry_add "$_u" "$_uid" "$_gid" "$_home" "$USRMANAGE_SHELL" || return 1
		um_shadow_entry_add "$_u" || return 1
		um_home_create "$_u" "$_uid" "$_gid" "$_home" || return 1
	fi
	_uid=$(um_user_uid "$_u") || return 1
	if [ "$_uid" -lt "$USRMANAGE_UID_FLOOR" ]; then
		um_delete_account "$_u" 1 || true
		um_err "error: allocated UID ${_uid} below floor ${USRMANAGE_UID_FLOOR}"
		return 1
	fi
	if [ "$_role" = "admin" ]; then
		um_wheel_add_user "$_u" || {
			um_delete_account "$_u" 1 || true
			return 1
		}
	fi
	return 0
}

um_doctor_checks() {
	_ok=1
	_json_checks=
	_add_check() {
		_id=$1
		_cok=$2
		_msg=$3
		if [ -n "$_json_checks" ]; then
			_json_checks="${_json_checks},"
		fi
		_em=$(printf '%s' "$_msg" | um_json_escape)
		_json_checks="${_json_checks}{\"id\":\"${_id}\",\"ok\":${_cok},\"msg\":\"${_em}\"}"
		[ "$_cok" = "true" ] || _ok=0
	}

	if command -v sudo >/dev/null 2>&1; then
		_add_check sudo true "sudo present"
	else
		_add_check sudo false "sudo missing"
	fi

	# Tool presence is preference info only — stock images use busybox fallbacks.
	if command -v useradd >/dev/null 2>&1 || command -v adduser >/dev/null 2>&1; then
		_add_check useradd true "useradd/adduser present (preferred)"
	else
		_add_check useradd true "useradd/adduser absent; using busybox file fallback"
	fi

	if command -v userdel >/dev/null 2>&1 || command -v deluser >/dev/null 2>&1; then
		_add_check userdel true "userdel/deluser present (preferred)"
	else
		_add_check userdel true "userdel/deluser absent; using busybox file fallback"
	fi

	# Fallback prerequisites: writable account files + home parent + registry.
	# Missing HOME_ROOT is OK — um_home_create does mkdir -p; require a writable
	# ancestor so create can succeed.
	_paths_ok=1
	_paths_msg=
	for _p in "$USRMANAGE_PASSWD" "$USRMANAGE_SHADOW" "$USRMANAGE_GROUP"; do
		if [ ! -f "$_p" ]; then
			_paths_ok=0
			_paths_msg="missing ${_p}"
			break
		fi
		if [ ! -w "$_p" ]; then
			_paths_ok=0
			_paths_msg="not writable ${_p}"
			break
		fi
	done
	if [ "$_paths_ok" = "1" ]; then
		_regdir=$(dirname "$USRMANAGE_REGISTRY")
		if [ ! -d "$_regdir" ] || [ ! -w "$_regdir" ]; then
			_paths_ok=0
			_paths_msg="registry dir not writable"
		elif [ -d "$USRMANAGE_HOME_ROOT" ]; then
			if [ ! -w "$USRMANAGE_HOME_ROOT" ]; then
				_paths_ok=0
				_paths_msg="home parent not writable"
			fi
		else
			_hr_parent=$(dirname "$USRMANAGE_HOME_ROOT")
			if [ ! -d "$_hr_parent" ] || [ ! -w "$_hr_parent" ]; then
				_paths_ok=0
				_paths_msg="home parent not creatable"
			fi
		fi
	fi
	if [ "$_paths_ok" = "1" ]; then
		_add_check fallback_paths true "passwd/shadow/group/registry/home writable"
	else
		_add_check fallback_paths false "fallback paths: ${_paths_msg}"
	fi

	if grep -q '^wheel:' "$USRMANAGE_GROUP" 2>/dev/null; then
		_add_check wheel true "wheel group present"
	else
		_add_check wheel false "wheel group missing"
	fi

	if [ -f "$USRMANAGE_SUDOERS" ]; then
		if command -v visudo >/dev/null 2>&1; then
			if visudo -cf "$USRMANAGE_SUDOERS" >/dev/null 2>&1; then
				_add_check sudoers true "sudoers fragment ok"
			else
				_add_check sudoers false "sudoers fragment invalid"
			fi
		else
			_add_check sudoers true "sudoers fragment present (visudo unavailable)"
		fi
	else
		_add_check sudoers false "sudoers fragment missing"
	fi

	if [ -d "$USRMANAGE_ETC" ] && [ -f "$USRMANAGE_REGISTRY" ]; then
		_add_check registry true "registry ok"
	else
		_add_check registry false "registry missing"
	fi

	if [ -d "$USRMANAGE_AUDIT_DIR" ]; then
		_add_check audit true "audit dir ok"
	else
		_add_check audit false "audit dir missing"
	fi

	if command -v flock >/dev/null 2>&1; then
		_add_check flock true "flock present"
	else
		_add_check flock false "flock missing (required for safe locks)"
	fi

	_add_check lock true "lock path $(dirname "$USRMANAGE_LOCK")"

	# Orphaned tx snapdirs (partial restore kept them for recovery; tmpfs).
	# Skip while the op lock is held — in-flight mutators keep a live snapdir.
	_tx_orphan_msg=
	_tx_orphan_count=0
	_tx_lock_busy=0
	if command -v flock >/dev/null 2>&1; then
		if ! ( flock -n 9 || exit 1 ) 9>"$USRMANAGE_LOCK"; then
			_tx_lock_busy=1
		fi
	fi
	if [ "$_tx_lock_busy" = "1" ]; then
		_add_check tx_snapdirs true "tx lock held; snapdir scan skipped"
	else
		for _tx_d in "${TMPDIR:-/tmp}"/usrmanage-tx.*; do
			[ -d "$_tx_d" ] || continue
			_tx_orphan_count=$((_tx_orphan_count + 1))
			if [ -z "$_tx_orphan_msg" ]; then
				_tx_orphan_msg=$_tx_d
			else
				_tx_orphan_msg="${_tx_orphan_msg} ${_tx_d}"
			fi
		done
		if [ "$_tx_orphan_count" -eq 0 ]; then
			_add_check tx_snapdirs true "no orphaned tx snapdirs"
		else
			_add_check tx_snapdirs false "orphaned tx snapdirs: ${_tx_orphan_msg}"
		fi
	fi

	_incomplete=
	if [ -f "$USRMANAGE_INCOMPLETE" ]; then
		_inc=$(cat "$USRMANAGE_INCOMPLETE" 2>/dev/null)
		_ie=$(printf '%s' "$_inc" | um_json_escape)
		_incomplete="\"${_ie}\""
		_ok=0
	fi

	if [ "${1:-}" = "--json" ] || [ "${JSON_OUT:-0}" = "1" ]; then
		_dok=true
		[ "$_ok" = "1" ] || _dok=false
		_pol=$(um_policy_json_name | tr -d '\n')
		if [ -z "$_incomplete" ]; then
			printf '{"ok":%s,"checks":[%s],"incomplete":[],"policy":%s}\n' "$_dok" "$_json_checks" "$_pol"
		else
			printf '{"ok":%s,"checks":[%s],"incomplete":[%s],"policy":%s}\n' "$_dok" "$_json_checks" "$_incomplete" "$_pol"
		fi
	else
		printf 'doctor ok=%s\n' "$_ok"
		um_policy_load
		printf 'policy=%s min_length=%s\n' "$UM_POL_PRESET" "$UM_POL_MIN_LENGTH"
		[ ! -f "$USRMANAGE_INCOMPLETE" ] || um_err "incomplete: $(cat "$USRMANAGE_INCOMPLETE")"
	fi
	[ "$_ok" = "1" ]
}

um_emit_user_json() {
	_u=$1
	_managed=false
	um_is_managed "$_u" && _managed=true
	_uid=$(um_user_uid "$_u" 2>/dev/null) || _uid=0
	_gid=$(um_user_gid "$_u" 2>/dev/null) || _gid=0
	_home=$(um_user_home "$_u" 2>/dev/null) || _home=
	_shell=$(um_user_shell "$_u" 2>/dev/null) || _shell=
	_role=$(um_role_of "$_u")
	_locked=false
	um_user_locked "$_u" && _locked=true
	_nu=$(printf '%s' "$_u" | um_json_escape)
	_nh=$(printf '%s' "$_home" | um_json_escape)
	_ns=$(printf '%s' "$_shell" | um_json_escape)
	printf '{"name":"%s","uid":%s,"gid":%s,"role":"%s","shell":"%s","home":"%s","managed":%s,"locked":%s}' \
		"$_nu" "$_uid" "$_gid" "$_role" "$_ns" "$_nh" "$_managed" "$_locked"
}

um_cmd_list() {
	_all=0
	_json=0
	for _a in "$@"; do
		case "$_a" in
			--all) _all=1 ;;
			--json) _json=1 ;;
		esac
	done
	_first=1
	if [ "$_json" = "1" ]; then
		printf '{"users":['
	fi
	if [ "$_all" = "1" ]; then
		while IFS=: read -r _name _x _uid _rest; do
			[ -n "$_name" ] || continue
			case "$_name" in \#*) continue ;; esac
			[ "$_uid" -ge "$USRMANAGE_UID_FLOOR" ] 2>/dev/null || continue
			if [ "$_json" = "1" ]; then
				[ "$_first" = "1" ] || printf ','
				_first=0
				um_emit_user_json "$_name"
			else
				_m=no
				um_is_managed "$_name" && _m=yes
				printf '%s uid=%s role=%s managed=%s\n' "$_name" "$_uid" "$(um_role_of "$_name")" "$_m"
			fi
		done < "$USRMANAGE_PASSWD"
	else
		[ -f "$USRMANAGE_REGISTRY" ] || {
			[ "$_json" = "1" ] && printf ']}\n'
			return 0
		}
		while IFS= read -r _name || [ -n "$_name" ]; do
			case "$_name" in ''|\#*) continue ;; esac
			um_user_exists "$_name" || continue
			if [ "$_json" = "1" ]; then
				[ "$_first" = "1" ] || printf ','
				_first=0
				um_emit_user_json "$_name"
			else
				printf '%s uid=%s role=%s managed=yes\n' "$_name" "$(um_user_uid "$_name")" "$(um_role_of "$_name")"
			fi
		done < "$USRMANAGE_REGISTRY"
	fi
	if [ "$_json" = "1" ]; then
		printf ']}\n'
	fi
}

um_cmd_show() {
	_json=0
	_name=
	for _a in "$@"; do
		case "$_a" in
			--json) _json=1 ;;
			*) _name=$_a ;;
		esac
	done
	[ -n "$_name" ] || um_die "usage: usrmanage show <user> [--json]"
	um_validate_username "$_name" || um_die "error: invalid_username"
	um_user_exists "$_name" || um_die "error: not_found"
	if [ "$_json" = "1" ]; then
		printf '{"user":'
		um_emit_user_json "$_name"
		printf '}\n'
	else
		um_emit_user_json "$_name"
		printf '\n'
	fi
}

um_cmd_audit() {
	_json=0
	_last=50
	_prev=
	for _a in "$@"; do
		case "$_a" in
			--json) _json=1 ;;
			--last) _prev=last ;;
			*)
				if [ "$_prev" = "last" ]; then
					_last=$_a
					_prev=
				fi
				;;
		esac
	done
	um_ensure_dirs
	case "$_last" in
		''|*[!0-9]*) _last=50 ;;
	esac
	if [ "$_json" = "1" ]; then
		printf '{"events":['
		_first=1
		tail -n "$_last" "$USRMANAGE_AUDIT" 2>/dev/null | while IFS= read -r _line || [ -n "$_line" ]; do
			[ -n "$_line" ] || continue
			# Parse compact line into JSON object (best-effort)
			_ts=$(printf '%s' "$_line" | awk '{print $1}')
			_action=$(printf '%s' "$_line" | awk '{print $2}')
			_user=$(printf '%s' "$_line" | sed -n 's/.* user=\([^ ]*\).*/\1/p')
			_role=$(printf '%s' "$_line" | sed -n 's/.* role=\([^ ]*\).*/\1/p')
			_actor=$(printf '%s' "$_line" | sed -n 's/.* actor=\([^ ]*\).*/\1/p')
			_src=$(printf '%s' "$_line" | sed -n 's/.* src=\([^ ]*\).*/\1/p')
			_result=$(printf '%s' "$_line" | sed -n 's/.* result=\([^ ]*\).*/\1/p')
			_reason=$(printf '%s' "$_line" | sed -n 's/.* reason=\([^ ]*\).*/\1/p')
			_jo=$(printf '{"ts":"%s","action":"%s","user":"%s","role":"%s","actor":"%s","src":"%s","result":"%s"' \
				"$(printf '%s' "$_ts" | um_json_escape)" \
				"$(printf '%s' "$_action" | um_json_escape)" \
				"$(printf '%s' "$_user" | um_json_escape)" \
				"$(printf '%s' "$_role" | um_json_escape)" \
				"$(printf '%s' "$_actor" | um_json_escape)" \
				"$(printf '%s' "$_src" | um_json_escape)" \
				"$(printf '%s' "$_result" | um_json_escape)")
			if [ -n "$_reason" ]; then
				_jo="${_jo},\"reason\":\"$(printf '%s' "$_reason" | um_json_escape)\"}"
			else
				_jo="${_jo}}"
			fi
			if [ "$_first" = "1" ]; then
				printf '%s' "$_jo"
				_first=0
			else
				printf ',%s' "$_jo"
			fi
		done
		printf ']}\n'
	else
		tail -n "$_last" "$USRMANAGE_AUDIT" 2>/dev/null || true
	fi
}


# Mutator shared prologue / failure helpers (refactor #47).
um_mut_require_valid_username() {
	# um_mut_require_valid_username <user> <role>
	um_validate_username "$1" || {
		um_audit denied "$1" denied invalid_username "$2"
		um_die "error: invalid_username"
	}
}

um_mut_require_managed() {
	# um_mut_require_managed <user> <role>
	um_is_managed "$1" || {
		um_audit denied "$1" denied unmanaged "$2"
		um_die "error: unmanaged"
	}
}

um_mut_require_exists() {
	# um_mut_require_exists <user> <role> <reason>
	um_user_exists "$1" || {
		um_audit denied "$1" denied "$3" "$2"
		um_die "error: $3"
	}
}

um_mut_fail() {
	# um_mut_fail <user> <role> <home> <home_existed> <audit_reason> <die_message>
	# Never rm -rf a pre-existing home.
	if [ "$4" = "0" ]; then
		um_home_remove "$3" 2>/dev/null || true
	fi
	um_tx_rollback || um_die "error: tx_restore_failed path=$UM_TX_SNAPDIR"
	um_incomplete_clear
	um_audit fail "$1" fail "$5" "$2"
	um_die "$6"
}

um_set_password() {
	# um_set_password <user> <password_fd_or_empty>
	if [ -n "$2" ]; then
		um_set_password_from_fd "$1" "$2"
	else
		um_set_password_prompt "$1"
	fi
}

um_mut_add() {
	_name=$1
	_role=$2
	_pfd=$3
	um_mut_require_valid_username "$_name" "$_role"
	um_validate_role "$_role" || {
		um_audit denied "$_name" denied invalid_role
		um_die "error: invalid_role"
	}
	um_user_exists "$_name" && {
		um_audit denied "$_name" denied exists "$_role"
		um_die "error: exists"
	}
	um_ensure_wheel_group || {
		um_audit denied "$_name" denied wheel_missing "$_role"
		um_die "error: wheel_missing"
	}
	_home="${USRMANAGE_HOME_ROOT}/${_name}"
	_home_existed=0
	[ -e "$_home" ] && _home_existed=1
	um_tx_begin
	um_incomplete_set "add:${_name}"
	um_create_user "$_name" "$_role" || um_mut_fail "$_name" "$_role" "$_home" "$_home_existed" create "error: create_failed"
	um_set_password "$_name" "$_pfd" || um_mut_fail "$_name" "$_role" "$_home" "$_home_existed" password "error: password_policy:${UM_POL_FAIL_REASON:-failed}"
	um_registry_add "$_name" || um_mut_fail "$_name" "$_role" "$_home" "$_home_existed" registry "error: registry_failed"
	um_tx_commit
	um_incomplete_clear
	um_audit grant "$_name" ok "" "$_role"
	if [ "${JSON_OUT:-0}" = "1" ]; then
		printf '{"ok":true,"name":"%s","role":"%s"}\n' \
			"$(printf '%s' "$_name" | um_json_escape)" "$_role"
	else
		printf 'ok: added %s role=%s\n' "$_name" "$_role"
	fi
}

um_mut_set_role() {
	_name=$1
	_role=$2
	um_mut_require_valid_username "$_name" "$_role"
	um_validate_role "$_role" || {
		um_audit denied "$_name" denied invalid_role
		um_die "error: invalid_role"
	}
	um_mut_require_managed "$_name" "$_role"
	um_mut_require_exists "$_name" "$_role" not_found
	_cur=$(um_role_of "$_name")
	if [ "$_cur" = "admin" ] && [ "$_role" = "readonly" ]; then
		_n=$(um_count_managed_admins)
		if [ "$_n" -le 1 ]; then
			um_audit denied "$_name" denied last_admin "$_role"
			um_die "error: last_admin"
		fi
	fi
	um_incomplete_set "set-role:${_name}:${_role}"
	if [ "$_role" = "admin" ]; then
		um_wheel_add_user "$_name" || {
			um_incomplete_clear
			um_audit fail "$_name" fail wheel_add "$_role"
			um_die "error: wheel_add_failed"
		}
	else
		um_wheel_del_user "$_name" || {
			um_incomplete_clear
			um_audit fail "$_name" fail wheel_del "$_role"
			um_die "error: wheel_del_failed"
		}
	fi
	um_incomplete_clear
	um_audit role "$_name" ok "from=${_cur}" "$_role"
	if [ "${JSON_OUT:-0}" = "1" ]; then
		printf '{"ok":true,"name":"%s","role":"%s"}\n' \
			"$(printf '%s' "$_name" | um_json_escape)" "$_role"
	else
		printf 'ok: %s role %s -> %s\n' "$_name" "$_cur" "$_role"
	fi
}

um_mut_passwd() {
	_name=$1
	_pfd=$2
	um_mut_require_valid_username "$_name" "$_role"
	um_mut_require_managed "$_name" "$_role"
	um_mut_require_exists "$_name" "$_role" not_found
	um_incomplete_set "passwd:${_name}"
	um_set_password "$_name" "$_pfd" || {
		um_incomplete_clear
		um_audit fail "$_name" fail password
		um_die "error: password_policy:${UM_POL_FAIL_REASON:-failed}"
	}
	um_incomplete_clear
	um_audit passwd "$_name" ok "" "$(um_role_of "$_name")"
	if [ "${JSON_OUT:-0}" = "1" ]; then
		printf '{"ok":true,"name":"%s"}\n' "$(printf '%s' "$_name" | um_json_escape)"
	else
		printf 'ok: password updated for %s\n' "$_name"
	fi
}

um_mut_del() {
	_name=$1
	_purge=$2
	um_mut_require_valid_username "$_name" "$_role"
	um_mut_require_managed "$_name" "$_role"
	um_mut_require_exists "$_name" "$_role" not_found
	_role=$(um_role_of "$_name")
	if [ "$_role" = "admin" ]; then
		_n=$(um_count_managed_admins)
		if [ "$_n" -le 1 ]; then
			um_audit denied "$_name" denied last_admin "$_role"
			um_die "error: last_admin"
		fi
	fi
	um_tx_begin
	um_incomplete_set "del:${_name}"
	um_lock_account "$_name" || um_mut_fail "$_name" "$_role" "" 0 lock "error: lock_failed"
	um_kill_user_procs "$_name"
	um_wheel_del_user "$_name" || um_mut_fail "$_name" "$_role" "" 0 wheel_del "error: wheel_del_failed"
	um_delete_account "$_name" "$_purge" || um_mut_fail "$_name" "$_role" "" 0 delete "error: delete_failed"
	# Commit before registry_del: purge may have removed the home already, so
	# EXIT rollback must not recreate passwd/shadow/group without a home.
	um_tx_commit
	um_registry_del "$_name" || {
		um_incomplete_clear
		um_audit fail "$_name" fail registry "$_role"
		um_die "error: registry_failed"
	}
	um_incomplete_clear
	um_audit remove "$_name" ok "" "$_role"
	if [ "${JSON_OUT:-0}" = "1" ]; then
		printf '{"ok":true,"name":"%s"}\n' "$(printf '%s' "$_name" | um_json_escape)"
	else
		printf 'ok: removed %s\n' "$_name"
	fi
}
