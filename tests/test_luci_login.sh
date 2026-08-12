#!/bin/sh
# Host tests for opt-in LuCI login lifecycle (issue #86).
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB="$ROOT/openwrt-feed/usrmanage/files/usr/lib/usrmanage/usrmanage-lib.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export USRMANAGE_LIB_DIR=$(dirname "$LIB")
export USRMANAGE_ETC="$TMP/etc"
export USRMANAGE_REGISTRY="$TMP/etc/users"
export USRMANAGE_AUDIT_DIR="$TMP/log"
export USRMANAGE_AUDIT="$TMP/log/audit.log"
export USRMANAGE_LOCK="$TMP/lock/usrmanage.lock"
export USRMANAGE_INCOMPLETE="$TMP/etc/incomplete"
export USRMANAGE_PASSWD="$TMP/passwd"
export USRMANAGE_SHADOW="$TMP/shadow"
export USRMANAGE_GROUP="$TMP/group"
export USRMANAGE_SUDOERS="$TMP/sudoers"
export USRMANAGE_RPCD_CONFIG="$TMP/rpcd"
export USRMANAGE_HOME_ROOT="$TMP/home"
export USRMANAGE_DRY_RUN=1
export USRMANAGE_SRC=cli
export USRMANAGE_ACTOR=testhost
export USRMANAGE_TEST_OVERRIDES=1
export JSON_OUT=0

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")" "$TMP/bin" "$USRMANAGE_HOME_ROOT"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
# Usable shadow hash (not empty / locked) — C1 gate
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\naudit:x:1001:1001:audit:/home/audit:/bin/ash\nempty:x:1003:1003:empty:/home/empty:/bin/ash\nlocked:x:1004:1004:locked:/home/locked:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:$6$salt$hash:0:99999:7:::\nops:$6$salt$ophash:0:99999:7:::\naudit:$6$salt$auhash:0:99999:7:::\nempty::0:99999:7:::\nlocked:!:0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\naudit\nempty\nlocked\n' > "$USRMANAGE_REGISTRY"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"

# shellcheck disable=SC1090
. "$LIB"
. "$ROOT/tests/lib.sh"

fail=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*" >&2; fail=1; }

command -v um_luci_login_state >/dev/null 2>&1 && ok "luci-login helpers sourced" || bad "luci-login helpers missing"

[ "$(um_luci_login_state ops)" = "none" ] && ok "initial state none" || bad "expected none got $(um_luci_login_state ops)"

# empty hash refused
if um_with_lock um_mut_set_luci_login empty enable 2>/dev/null; then
	bad "empty hash should refuse enable"
else
	ok "empty hash refused"
fi
if grep -q 'no_password' "$USRMANAGE_AUDIT" 2>/dev/null; then
	ok "no_password audited"
else
	bad "no_password not audited"
fi

# locked shadow (!) refused
_np_before=$(grep -c 'no_password' "$USRMANAGE_AUDIT" 2>/dev/null || true)
_lerr=$(um_with_lock um_mut_set_luci_login locked enable 2>&1) && bad "locked ! should refuse enable" || ok "locked ! refused"
printf '%s' "$_lerr" | grep -q 'no_password' && ok "locked ! denial token" || bad "locked ! token: $_lerr"
_np_after=$(grep -c 'no_password' "$USRMANAGE_AUDIT" 2>/dev/null || true)
[ "$_np_after" -gt "$_np_before" ] && ok "locked ! audited" || bad "locked ! audit count $_np_before -> $_np_after"
# locked shadow (*) refused
_awk_tmp=$(mktemp)
awk -F: 'BEGIN{OFS=":"} $1=="locked"{$2="*"} {print}' "$USRMANAGE_SHADOW" > "$_awk_tmp" && mv "$_awk_tmp" "$USRMANAGE_SHADOW"
_np_before=$(grep -c 'no_password' "$USRMANAGE_AUDIT" 2>/dev/null || true)
_lerr=$(um_with_lock um_mut_set_luci_login locked enable 2>&1) && bad "locked * should refuse enable" || ok "locked * refused"
printf '%s' "$_lerr" | grep -q 'no_password' && ok "locked * denial token" || bad "locked * token: $_lerr"
_np_after=$(grep -c 'no_password' "$USRMANAGE_AUDIT" 2>/dev/null || true)
[ "$_np_after" -gt "$_np_before" ] && ok "locked * audited" || bad "locked * audit count $_np_before -> $_np_after"

# pending UCI changes refuse enable (stub uci on PATH)
cat > "$TMP/bin/uci" <<'UCI'
#!/bin/sh
if [ "$1" = "changes" ] && [ "$2" = "rpcd" ]; then
	echo "rpcd.@login[0].username='staged'"
	exit 0
fi
exit 0
UCI
chmod +x "$TMP/bin/uci"
_oldpath=$PATH
export PATH="$TMP/bin:$PATH"
_perr=$(um_with_lock um_mut_set_luci_login ops enable 2>&1) && bad "pending uci should refuse enable" || ok "pending uci refused enable"
printf '%s' "$_perr" | grep -q 'rpcd_pending_changes' && ok "pending denial token" || bad "pending token: $_perr"
_perr=$(um_with_lock um_mut_set_luci_login ops disable 2>&1) && bad "pending uci should refuse disable" || ok "pending uci refused disable"
printf '%s' "$_perr" | grep -q 'rpcd_pending_changes' && ok "pending disable denial token" || bad "pending disable token: $_perr"
rm -f "$TMP/bin/uci"
export PATH="$_oldpath"

# enable owned login
um_with_lock um_mut_set_luci_login ops enable
[ "$(um_luci_login_state ops)" = "owned" ] && ok "enable → owned" || bad "enable state $(um_luci_login_state ops)"
grep -q "option password '\$p\$ops'" "$USRMANAGE_RPCD_CONFIG" && ok "password is \$p\$ops" || bad "bad password field"
grep -q "option usrmanage '1'" "$USRMANAGE_RPCD_CONFIG" && ok "ownership marker" || bad "missing marker"
grep -q "list read 'luci-app-usrmanage-session'" "$USRMANAGE_RPCD_CONFIG" && ok "session ACL" || bad "missing session ACL"
grep -q "list write 'luci-app-usrmanage'" "$USRMANAGE_RPCD_CONFIG" && ok "admin write ACL" || bad "missing write ACL"
grep -q 'luci_grant' "$USRMANAGE_AUDIT" && ok "luci_grant audited" || bad "luci_grant missing"

# second admin so demote is allowed
um_with_lock um_mut_set_role audit admin

# role demote sync drops write
um_with_lock um_mut_set_role ops readonly
grep -q "list write 'luci-app-usrmanage'" "$USRMANAGE_RPCD_CONFIG" && bad "write ACL should be gone after demote" || ok "demote dropped write"
[ "$(um_luci_login_state ops)" = "owned" ] && ok "still owned after demote" || bad "lost owned after demote"

# promote restores write
um_with_lock um_mut_set_role ops admin
grep -q "list write 'luci-app-usrmanage'" "$USRMANAGE_RPCD_CONFIG" && ok "promote restored write" || bad "write missing after promote"

# foreign collision
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

config login
	option username 'audit'
	option password '$6$other$hash'
	list read '*'
	list write '*'
EOF
[ "$(um_luci_login_state audit)" = "foreign" ] && ok "foreign detected" || bad "foreign state $(um_luci_login_state audit)"
_ferr=$(um_with_lock um_mut_set_luci_login audit enable 2>&1) && bad "foreign should refuse enable" || ok "foreign refuse enable"
printf '%s' "$_ferr" | grep -q 'login_exists_foreign' && ok "foreign denial token" || bad "foreign token: $_ferr"

# tampered marker (wrong password)
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

config login
	option username 'empty'
	option password 'not-p-form'
	option usrmanage '1'
	list read 'luci-app-usrmanage'
EOF
[ "$(um_luci_login_state empty)" = "tampered" ] && ok "tampered detected" || bad "tampered state $(um_luci_login_state empty)"

# ACL drift on owned login → tampered; sync repairs
um_with_lock um_mut_set_luci_login ops enable
# inject extra ACL grant
sed -i "/option username 'ops'/,/^config /{ /list write/a\\
	list write 'luci-app-firewall'
}" "$USRMANAGE_RPCD_CONFIG" 2>/dev/null || {
	# portable append after ops write line
	_awk_tmp=$(mktemp)
	awk '
		/^config login/ { inops=0 }
		/option username '\''ops'\''/ { inops=1 }
		{ print }
		inops && /list write '\''luci-app-usrmanage'\''/ {
			print "\tlist write '\''luci-app-firewall'\''"
			inops=0
		}
	' "$USRMANAGE_RPCD_CONFIG" > "$_awk_tmp" && mv "$_awk_tmp" "$USRMANAGE_RPCD_CONFIG"
}
[ "$(um_luci_login_state ops)" = "tampered" ] && ok "ACL drift → tampered" || bad "ACL drift state $(um_luci_login_state ops)"
um_with_lock um_mut_set_role ops admin
[ "$(um_luci_login_state ops)" = "owned" ] && ok "set-role sync repairs ACL drift" || bad "repair state $(um_luci_login_state ops)"
grep -q "luci-app-firewall" "$USRMANAGE_RPCD_CONFIG" && bad "extra ACL still present" || ok "extra ACL removed"

# disable owned
um_with_lock um_mut_set_luci_login ops disable
[ "$(um_luci_login_state ops)" = "none" ] && ok "disable → none" || bad "disable state $(um_luci_login_state ops)"
grep -q 'luci_revoke' "$USRMANAGE_AUDIT" && ok "luci_revoke audited" || bad "luci_revoke missing"

# del cleanup: enable, unregister path must not leave orphan login
um_with_lock um_mut_set_luci_login ops enable
[ "$(um_luci_login_state ops)" = "owned" ] || bad "pre-del enable failed"
# Simulate del cleanup ordering: remove while managed, then drop registry
um_luci_login_remove_owned_best_effort ops || bad "remove_owned failed"
um_registry_del ops || bad "registry_del failed"
_idx=$(um_luci_login_ours_index ops 1)
[ -z "$_idx" ] && ok "del cleanup removes ours login" || bad "orphan login remains idx=$_idx"
# restore ops for remaining tests
printf 'ops\naudit\nempty\nlocked\n' > "$USRMANAGE_REGISTRY"
printf 'root:x:0:\nwheel:x:10:ops,audit\n' > "$USRMANAGE_GROUP"

# Full del → um_mut_add without luci: must not resurrect orphan write ACL.
# DRY_RUN skips real userdel/useradd; scrub passwd/shadow so add sees a fresh name.
um_with_lock um_mut_set_role ops admin
um_with_lock um_mut_set_luci_login ops enable
grep -q "option password '\$p\$ops'" "$USRMANAGE_RPCD_CONFIG" || bad "pre-full-del missing \$p\$ops"
um_is_managed audit || bad "need second admin before del ops"
um_with_lock um_mut_del ops 0
_idx=$(um_luci_login_ours_index ops 1)
[ -z "$_idx" ] && ok "full del removes luci login" || bad "full del orphan idx=$_idx"
grep -q "option username 'ops'" "$USRMANAGE_RPCD_CONFIG" && bad "ops login section left after del" || ok "no ops login after del"
# Simulate account row removal that DRY_RUN um_delete_account skipped.
_awk_tmp=$(mktemp)
awk -F: -v u=ops '$1 != u' "$USRMANAGE_PASSWD" > "$_awk_tmp" && mv "$_awk_tmp" "$USRMANAGE_PASSWD"
awk -F: -v u=ops '$1 != u' "$USRMANAGE_SHADOW" > "$_awk_tmp" && mv "$_awk_tmp" "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:audit\n' > "$USRMANAGE_GROUP"
printf 'goodpass12\n' | um_with_lock um_mut_add ops readonly 0 0
um_is_managed ops && ok "um_mut_add re-created ops" || bad "um_mut_add did not register ops"
[ "$(um_luci_login_state ops)" = "none" ] && ok "re-add without luci stays none" || bad "re-add state $(um_luci_login_state ops)"
grep -q "option password '\$p\$ops'" "$USRMANAGE_RPCD_CONFIG" && bad "orphan \$p\$ops after um_mut_add" || ok "no orphan \$p\$ops after um_mut_add"
# Restore passwd/shadow rows (DRY_RUN create skipped them) for later enable tests.
printf 'ops:x:1002:1002:ops:/home/ops:/bin/ash\n' >> "$USRMANAGE_PASSWD"
printf 'ops:$6$salt$ophash:0:99999:7:::\n' >> "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops,audit\n' > "$USRMANAGE_GROUP"

# Owned + foreign coexistence: demote must drop write on ours via ours_index.
um_with_lock um_mut_set_luci_login ops enable
grep -q "list write 'luci-app-usrmanage'" "$USRMANAGE_RPCD_CONFIG" || bad "owned write missing before foreign"
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

config login
	option username 'ops'
	option password '$6$foreign$ops'
	list read '*'
	list write '*'
EOF
[ "$(um_luci_login_state ops)" = "foreign" ] && ok "owned+foreign aggregate foreign" || bad "aggregate $(um_luci_login_state ops)"
_ours=$(um_luci_login_ours_index ops)
[ -n "$_ours" ] && ok "ours_index finds owned amid foreign" || bad "ours_index empty amid foreign"
um_with_lock um_mut_set_role ops readonly
# Owned section must no longer grant app write; foreign '*' write may remain.
if awk '
	BEGIN { inlogin=0; isops=0; hasmark=0; haswrite=0 }
	/^config login/ {
		if (inlogin && isops && hasmark && haswrite) found=1
		inlogin=1; isops=0; hasmark=0; haswrite=0; next
	}
	inlogin && /option username '\''ops'\''/ { isops=1 }
	inlogin && /option usrmanage '\''1'\''/ { hasmark=1 }
	inlogin && /list write '\''luci-app-usrmanage'\''/ { haswrite=1 }
	END { if (inlogin && isops && hasmark && haswrite) found=1; exit !found }
' "$USRMANAGE_RPCD_CONFIG"; then
	bad "owned write sticky amid foreign"
else
	ok "demote dropped owned write amid foreign"
fi
grep -q "option password '\$6\$foreign\$ops'" "$USRMANAGE_RPCD_CONFIG" && ok "foreign section untouched" || bad "foreign section missing"
[ -n "$(um_luci_login_ours_index ops)" ] && ok "ours still present after demote" || bad "ours lost after demote"

# Reset rpcd leftovers so emit sees none for ops
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
um_with_lock um_mut_set_role ops admin

# emit json includes luci_login
_j=$(um_emit_user_json ops)
printf '%s' "$_j" | grep -q '"luci_login":"none"' && ok "emit luci_login" || bad "emit json: $_j"

# um_mut_add with luci_login=1 → owned readonly (no write ACL).
# DRY_RUN skips create/password writes; briefly use the busybox-fallback style
# PATH (no useradd) plus a hermetic chpasswd stub so only TMP files are touched.
_flock_abs=$(command -v flock) || bad "flock missing for add-with-luci"
ln -sf "$_flock_abs" "$TMP/bin/flock"
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/passwd"
cat > "$TMP/bin/chpasswd" <<'CHP'
#!/bin/sh
IFS= read -r line || exit 1
u=${line%%:*}
_tmp=$(mktemp)
awk -F: -v u="$u" 'BEGIN{OFS=":"} $1==u{$2="$6$testsalt$testhash"} {print}' \
	"$USRMANAGE_SHADOW" > "$_tmp" || exit 1
if grep -q "^${u}:" "$_tmp"; then
	mv "$_tmp" "$USRMANAGE_SHADOW"
else
	rm -f "$_tmp"
	printf '%s:$6$testsalt$testhash:0:99999:7:::\n' "$u" >> "$USRMANAGE_SHADOW" || exit 1
fi
chmod 0600 "$USRMANAGE_SHADOW" 2>/dev/null || true
exit 0
CHP
chmod +x "$TMP/bin/passwd" "$TMP/bin/chpasswd"
_oldpath=$PATH
export PATH="$TMP/bin:/usr/bin:/bin"
if command -v useradd >/dev/null 2>&1; then
	bad "useradd still on PATH for add-with-luci"
else
	ok "add-with-luci PATH hides useradd"
fi
USRMANAGE_DRY_RUN=0
printf 'goodpass12\n' | um_with_lock um_mut_add luciadd readonly 0 1
USRMANAGE_DRY_RUN=1
export PATH="$_oldpath"
rm -f "$TMP/bin/passwd" "$TMP/bin/chpasswd" "$TMP/bin/flock"
um_is_managed luciadd && ok "add-with-luci registered" || bad "luciadd not managed"
grep -q '^luciadd:\$6\$testsalt\$testhash:' "$USRMANAGE_SHADOW" && ok "add-with-luci shadow hash" || bad "luciadd shadow: $(grep '^luciadd:' "$USRMANAGE_SHADOW" 2>/dev/null || true)"
[ "$(um_luci_login_state luciadd)" = "owned" ] && ok "add-with-luci → owned" || bad "add-with-luci state $(um_luci_login_state luciadd)"
grep -q "option password '\$p\$luciadd'" "$USRMANAGE_RPCD_CONFIG" && ok "add-with-luci \$p\$luciadd" || bad "missing \$p\$luciadd"
grep -q "option usrmanage '1'" "$USRMANAGE_RPCD_CONFIG" && ok "add-with-luci marker" || bad "add-with-luci missing marker"
grep -q "list read 'luci-app-usrmanage-session'" "$USRMANAGE_RPCD_CONFIG" && ok "add-with-luci session ACL" || bad "add-with-luci missing session ACL"
# readonly must not get app write; ignore unrelated sections by checking luciadd block
if awk '
	BEGIN { inlogin=0; isadd=0; haswrite=0 }
	/^config login/ {
		if (inlogin && isadd && haswrite) found=1
		inlogin=1; isadd=0; haswrite=0; next
	}
	inlogin && /option username '\''luciadd'\''/ { isadd=1 }
	inlogin && /list write '\''luci-app-usrmanage'\''/ { haswrite=1 }
	END { if (inlogin && isadd && haswrite) found=1; exit !found }
' "$USRMANAGE_RPCD_CONFIG"; then
	bad "readonly add-with-luci has write ACL"
else
	ok "readonly add-with-luci has no write ACL"
fi

# --- M3: failed del rolls back the rpcd login removal (issue #94) ---
um_with_lock um_mut_set_luci_login ops enable
[ "$(um_luci_login_state ops)" = "owned" ] && ok "M3 pre: ops login owned" || bad "M3 pre: ops login $(um_luci_login_state ops)"
um_is_managed audit || bad "M3 pre: second admin missing for del ops"
if (
	# um_lock_account failing after the login removal must roll the whole
	# delete back, including the rpcd login.
	um_lock_account() { return 1; }
	um_with_lock um_mut_del ops 0 >/dev/null 2>&1
); then
	bad "M3: lock-failed del should be denied"
else
	ok "M3: lock-failed del denied"
fi
um_is_managed ops && ok "M3: ops still managed after rollback" || bad "M3: ops unregistered after rollback"
[ "$(um_luci_login_state ops)" = "owned" ] && ok "M3: rpcd login rolled back with account" || bad "M3: rpcd login lost after rollback: $(um_luci_login_state ops)"
grep -q "option password '\$p\$ops'" "$USRMANAGE_RPCD_CONFIG" && ok "M3: ops login section present after rollback" || bad "M3: ops login section missing after rollback"
grep -q 'reason=lock$' "$USRMANAGE_AUDIT" && ok "M3: lock failure audited" || bad "M3: lock failure not audited"

# --- M5/m1: demote ordering — revoke sessions BEFORE the ACL rewrite, and
# drop the web ACL BEFORE wheel (fail-safe crash direction) ---
_ord="$TMP/role_order"
rm -f "$_ord"
(
	um_session_revoke_user() { printf 'revoke\n' >> "$_ord"; return 0; }
	um_luci_login_sync_acls() { printf 'sync-acls\n' >> "$_ord"; return 0; }
	um_wheel_del_user() { printf 'wheel-del\n' >> "$_ord"; return 0; }
	um_with_lock um_mut_set_role ops readonly
)
_ord_seq=$(tr -d '\n' < "$_ord" 2>/dev/null)
if [ "$_ord_seq" = "revokesync-aclswheel-del" ]; then
	ok "M5/m1: demote order revoke→ACL→wheel"
else
	bad "M5/m1: demote order got '$_ord_seq'"
fi

# --- M5/m7: failed promote rolls back BOTH wheel and ACLs, and a
# rollback-sync failure is audited (not swallowed) ---
um_with_lock um_mut_set_role ops readonly
[ "$(um_luci_login_state ops)" = "owned" ] && ok "M5 pre: ops owned readonly" || bad "M5 pre: ops state $(um_luci_login_state ops)"
um_in_wheel ops && bad "M5 pre: ops still in wheel" || ok "M5 pre: ops readonly"
: > "$USRMANAGE_AUDIT"
if (
	# Simulate a partial promote: the ACL sync GRANTS the write ACL (mutation
	# happened) and then fails. Only tx rollback can undo the granted write
	# ACL — the assertion below must fail on a non-transactional impl.
	um_luci_login_sync_acls() {
		# Append the write grant to ops' login section (real mutation).
		_ll_awk_tmp=$(mktemp "${TMPDIR:-/tmp}/um-rpcd-test.XXXXXX") || return 1
		awk '
			/^config login/ { inlogin=1; print; next }
			inlogin && /option username '\''ops'\''/ { isops=1; print; next }
			inlogin && isops && /^[ 	]*list write/ { next }
			inlogin && isops && /option usrmanage/ {
				print
				print "	list write '\''luci-app-usrmanage'\''"
				next
			}
			{ print }
		' "$USRMANAGE_RPCD_CONFIG" > "$_ll_awk_tmp" || { rm -f "$_ll_awk_tmp"; return 1; }
		um_rpcd_atomic_replace "$_ll_awk_tmp" "$USRMANAGE_RPCD_CONFIG" || { rm -f "$_ll_awk_tmp"; return 1; }
		rm -f "$_ll_awk_tmp"
		return 1
	}
	um_with_lock um_mut_set_role ops admin >/dev/null 2>&1
); then
	bad "M5: failed promote should be denied"
else
	ok "M5: failed promote denied"
fi
um_in_wheel ops && bad "M5: ops left in wheel after failed promote" || ok "M5: wheel rolled back after failed promote"
if awk '
	BEGIN { inlogin=0; isops=0; hasmark=0; haswrite=0 }
	/^config login/ {
		if (inlogin && isops && hasmark && haswrite) found=1
		inlogin=1; isops=0; hasmark=0; haswrite=0; next
	}
	inlogin && /option username '\''ops'\''/ { isops=1 }
	inlogin && /option usrmanage '\''1'\''/ { hasmark=1 }
	inlogin && /list write '\''luci-app-usrmanage'\''/ { haswrite=1 }
	END { if (inlogin && isops && hasmark && haswrite) found=1; exit !found }
' "$USRMANAGE_RPCD_CONFIG"; then
	bad "M5: write ACL granted despite failed promote"
else
	ok "M5: no write ACL after failed promote"
fi
grep -q 'reason=luci_login_sync$' "$USRMANAGE_AUDIT" && ok "M5: sync failure audited" || bad "M5: sync failure not audited"
grep -q 'reason=luci_login_rollback$' "$USRMANAGE_AUDIT" && ok "m7: rollback-sync failure audited" || bad "m7: rollback-sync failure not audited"
# --- Fix 1 (M2): reset recovery path ---

# Reset clears a tampered (marker + wrong password) login to none
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
um_with_lock um_mut_set_luci_login ops enable
[ "$(um_luci_login_state ops)" = "owned" ] || bad "pre-reset enable failed"
# Inject tampered state: wrong password with marker
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

config login
	option username 'ops'
	option password 'wrong-password'
	option usrmanage '1'
	list read 'luci-app-usrmanage-session'
	list read 'luci-app-usrmanage'
EOF
[ "$(um_luci_login_state ops)" = "tampered" ] || bad "tampered state before reset"
um_with_lock um_mut_set_luci_login ops reset
[ "$(um_luci_login_state ops)" = "none" ] && ok "reset clears tampered to none" || bad "reset state $(um_luci_login_state ops)"
grep -q 'luci_revoke' "$USRMANAGE_AUDIT" || bad "reset missing luci_revoke audit"

# Reset skips pure foreign login (no marker) — should succeed (no-op on foreign)
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

config login
	option username 'ops'
	option password '$6$foreign$hash'
	list read '*'
	list write '*'
EOF
[ "$(um_luci_login_state ops)" = "foreign" ] || bad "foreign state before reset"
um_with_lock um_mut_set_luci_login ops reset
[ "$(um_luci_login_state ops)" = "foreign" ] && ok "reset skips pure foreign" || bad "reset changed foreign $(um_luci_login_state ops)"

# Reset on none is a no-op success (idempotent)
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
[ "$(um_luci_login_state ops)" = "none" ] || bad "pre-idempotent state"
um_with_lock um_mut_set_luci_login ops reset && ok "reset on none succeeds" || bad "reset on none failed"
[ "$(um_luci_login_state ops)" = "none" ] && ok "reset on none stays none" || bad "reset on none state $(um_luci_login_state ops)"

# --- Fix 4 (m3): pipe-in-password delimiter ---

printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

config login
	option username 'ops'
	option password 'pl|ain|pass|word'
	list read '*'
	list write '*'
EOF
[ "$(um_luci_login_state ops)" = "foreign" ] && ok "pipe in password classified foreign" || bad "pipe password state $(um_luci_login_state ops)"

# --- Fix 6 (m6): multiple owned sections ---

printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
um_with_lock um_mut_set_luci_login ops enable
# Duplicate the owned section
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

config login
	option username 'ops'
	option password '$p$ops'
	option usrmanage '1'
	list read 'luci-app-usrmanage-session'
	list read 'luci-app-usrmanage'
	list write 'luci-app-usrmanage'
EOF
_idx_count=$(um_luci_login_ours_index ops | grep -c '.' || true)
[ "$_idx_count" -ge 2 ] && ok "ours_index returns multiple" || bad "ours_index count=$_idx_count"
[ "$(um_luci_login_state ops)" = "tampered" ] || bad "multi-owned should be tampered"
um_with_lock um_mut_set_luci_login ops reset
[ "$(um_luci_login_state ops)" = "none" ] && ok "reset removes all owned sections" || bad "reset multi state $(um_luci_login_state ops)"
_idx_count2=$(um_luci_login_ours_index ops 1 | wc -l | tr -d ' ')
[ "$_idx_count2" = "0" ] && ok "no owned sections remain after reset" || bad "remaining count=$_idx_count2"

# Disable also removes all owned sections
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
um_with_lock um_mut_set_luci_login ops enable
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

config login
	option username 'ops'
	option password '$p$ops'
	option usrmanage '1'
	list read 'luci-app-usrmanage-session'
	list read 'luci-app-usrmanage'
	list write 'luci-app-usrmanage'
EOF
[ "$(um_luci_login_state ops)" = "tampered" ] || bad "multi-owned disable pre-check"
um_with_lock um_mut_set_luci_login ops disable
[ "$(um_luci_login_state ops)" = "none" ] && ok "disable removes all owned sections" || bad "disable multi state $(um_luci_login_state ops)"

# --- Fix 3 (m2): invalid mode denial audit ---

_np_before=$(grep -c 'denied.*invalid_luci_login_mode' "$USRMANAGE_AUDIT" 2>/dev/null || true)
_lerr=$(um_with_lock um_mut_set_luci_login ops bogus 2>&1) && bad "bogus mode should fail" || ok "bogus mode refused"
printf '%s' "$_lerr" | grep -q 'invalid_luci_login_mode' && ok "bogus mode denial token" || bad "bogus mode token: $_lerr"
_np_after=$(grep -c 'denied.*invalid_luci_login_mode' "$USRMANAGE_AUDIT" 2>/dev/null || true)
[ "$_np_after" -gt "$_np_before" ] && ok "invalid mode audited" || bad "invalid mode audit count $_np_before -> $_np_after"

# --- Fix 2 (M6): mktemp failure simulation ---

printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
um_with_lock um_mut_set_luci_login ops enable
[ "$(um_luci_login_state ops)" = "owned" ] || bad "pre-mktemp state"
# Point TMPDIR to a non-existent path to cause mktemp failure
_nonexistent="${TMPDIR:-/tmp}/.usrmanage-mktemp-fail-test-$$"
_old_tmpdir=${TMPDIR:-}
export TMPDIR="$_nonexistent"
_mktemp_err=$(um_luci_login_state ops 2>&1) && {
	bad "mktemp failure should not succeed"
} || ok "mktemp failure returns non-zero"
# Enable must be denied while the state check still fails — keep the broken
# TMPDIR in effect THROUGH the mutator call (restoring it first would let the
# enable succeed and make this assertion vacuous).
_mktemp_enterr=$(um_with_lock um_mut_set_luci_login ops enable 2>&1) && bad "enable after mktemp fail should be denied" || ok "enable denied on mktemp failure"
export TMPDIR="$_old_tmpdir"
printf '%s' "$_mktemp_enterr" | grep -q 'luci_login_state' && ok "mktemp failure denial token" || bad "mktemp failure token: $_mktemp_enterr"
# Verify state check still works after TMPDIR is restored
[ "$(um_luci_login_state ops)" = "owned" ] && ok "state works after TMPDIR restore" || bad "state after restore $(um_luci_login_state ops)"

# --- Fix 5 (m5): top-level luci_login audit event ---

grep -q 'luci_login.*ok.*mode=enable' "$USRMANAGE_AUDIT" && ok "top-level luci_login audit on enable" || bad "luci_login enable audit missing"

# --- L5: /etc/config/rpcd mode preserved across enable/disable/reset/rollback ---

printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
chmod 0600 "$USRMANAGE_RPCD_CONFIG"
um_with_lock um_mut_set_luci_login ops enable
_mode=$(stat_mode "$USRMANAGE_RPCD_CONFIG")
[ "$_mode" = "600" ] && ok "rpcd mode 0600 after enable" || bad "rpcd mode after enable: $_mode"
um_with_lock um_mut_set_luci_login ops disable
_mode=$(stat_mode "$USRMANAGE_RPCD_CONFIG")
[ "$_mode" = "600" ] && ok "rpcd mode 0600 after disable" || bad "rpcd mode after disable: $_mode"
um_with_lock um_mut_set_luci_login ops enable
um_with_lock um_mut_set_luci_login ops reset
_mode=$(stat_mode "$USRMANAGE_RPCD_CONFIG")
[ "$_mode" = "600" ] && ok "rpcd mode 0600 after reset" || bad "rpcd mode after reset: $_mode"

# Forced rollback must restore rpcd at 0600 (not the passwd|group 0644 arm).
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
chmod 0600 "$USRMANAGE_RPCD_CONFIG"
um_tx_begin
printf 'config rpcd\n\toption socket /changed\n\n' > "$USRMANAGE_RPCD_CONFIG"
chmod 0644 "$USRMANAGE_RPCD_CONFIG"
um_tx_rollback
_mode=$(stat_mode "$USRMANAGE_RPCD_CONFIG")
[ "$_mode" = "600" ] && ok "rpcd mode 0600 after tx rollback" || bad "rpcd mode after rollback: $_mode"
grep -q 'option socket /var/run/ubus/ubus.sock' "$USRMANAGE_RPCD_CONFIG" \
	&& ok "rpcd content restored on rollback" || bad "rpcd content not restored"

# --- L6: audit rotate writes under umask 077 + ends at 0640 ---

: "${USRMANAGE_AUDIT_MAX_BYTES:=131072}"
_old_max=$USRMANAGE_AUDIT_MAX_BYTES
USRMANAGE_AUDIT_MAX_BYTES=64
# Oversize the audit log so rotate triggers.
dd if=/dev/zero bs=1 count=200 of="$USRMANAGE_AUDIT" 2>/dev/null \
	|| head -c 200 /dev/zero > "$USRMANAGE_AUDIT"
chmod 0640 "$USRMANAGE_AUDIT"
umask 022
um_audit_rotate_if_needed
_mode=$(stat_mode "$USRMANAGE_AUDIT")
[ "$_mode" = "640" ] && ok "audit mode 0640 after rotate" || bad "audit mode after rotate: $_mode"
[ ! -f "${USRMANAGE_AUDIT}.1" ] && ok "audit rotate leaves no .1 leftover" \
	|| bad "audit .1 leftover after rotate"
USRMANAGE_AUDIT_MAX_BYTES=$_old_max

# --- L4: fail closed on libuci-valid forms the awk dump cannot see (#108) ---

_seed_unparsable() {
	# $1 = form: indented | abbreviated | quoted
	case "$1" in
		indented)
			cat > "$USRMANAGE_RPCD_CONFIG" <<'EOF'
config rpcd
	option socket /var/run/ubus/ubus.sock

	config login
		option username 'ops'
		option password '$1$FOREIGNSALT$foreignhashvalue'
		list read 'luci-base'
		list write 'luci-base'
EOF
			;;
		abbreviated)
			cat > "$USRMANAGE_RPCD_CONFIG" <<'EOF'
config rpcd
	option socket /var/run/ubus/ubus.sock

c login
	o username 'ops'
	o password '$1$FOREIGNSALT$foreignhashvalue'
	l read 'luci-base'
	l write 'luci-base'
EOF
			;;
		quoted)
			cat > "$USRMANAGE_RPCD_CONFIG" <<'EOF'
config rpcd
	option socket /var/run/ubus/ubus.sock

config 'login'
	option username 'ops'
	option password '$1$FOREIGNSALT$foreignhashvalue'
	list read 'luci-base'
	list write 'luci-base'
EOF
			;;
	esac
}

for _form in indented abbreviated quoted; do
	_seed_unparsable "$_form"
	if um_luci_login_state ops >/dev/null 2>&1; then
		bad "L4 $_form: state must fail closed"
	else
		ok "L4 $_form: state fails closed"
	fi
	_lerr=$(um_with_lock um_mut_set_luci_login ops disable 2>&1) && bad "L4 $_form: disable must not ok" \
		|| ok "L4 $_form: disable refused"
	printf '%s' "$_lerr" | grep -q 'rpcd_config_unparsable' \
		&& ok "L4 $_form: disable denial token" \
		|| bad "L4 $_form: token missing in: $_lerr"
	grep -q 'denied.*rpcd_config_unparsable' "$USRMANAGE_AUDIT" \
		&& ok "L4 $_form: denied audited" \
		|| bad "L4 $_form: denied not audited"
	# Section must still be present (we refused, did not silently "succeed").
	grep -q "username" "$USRMANAGE_RPCD_CONFIG" \
		&& ok "L4 $_form: login section still present after refused disable" \
		|| bad "L4 $_form: login section vanished"
done

# L4 follow-up: unparsable disable must still revoke live sessions.
_seed_unparsable abbreviated
rm -f "$TMP/l4_revoked"
(
	um_session_revoke_user() { printf '1' > "$TMP/l4_revoked"; return 0; }
	um_with_lock um_mut_set_luci_login ops disable >/dev/null 2>&1 || true
)
[ -f "$TMP/l4_revoked" ] && ok "L4 unparsable disable: session revoke called" \
	|| bad "L4 unparsable disable: session revoke skipped"

# L4 follow-up: mixed canonical owned + abbreviated hidden → set-role must refuse.
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
um_with_lock um_mut_set_luci_login ops enable
[ "$(um_luci_login_state ops)" = "owned" ] || bad "L4 mixed pre: enable owned"
cat >> "$USRMANAGE_RPCD_CONFIG" <<'EOF'

c login
	o username 'ops'
	o password '$1$HIDDEN$hiddenhash'
	l read '*'
	l write '*'
EOF
if um_with_lock um_mut_set_role ops readonly >/dev/null 2>&1; then
	bad "L4 mixed: set-role must refuse unparsable rpcd"
else
	ok "L4 mixed: set-role refused"
fi
# Visible owned section must not have been rewritten to readonly-only while hidden remains.
grep -q "c login" "$USRMANAGE_RPCD_CONFIG" \
	&& ok "L4 mixed: hidden section still present (refused, not partially synced)" \
	|| bad "L4 mixed: hidden section vanished"

# Canonical form still works after the fail-closed gate.
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
[ "$(um_luci_login_state ops)" = "none" ] && ok "L4 canonical: state none" \
	|| bad "L4 canonical state $(um_luci_login_state ops 2>/dev/null || echo fail)"
um_with_lock um_mut_set_luci_login ops enable
[ "$(um_luci_login_state ops)" = "owned" ] && ok "L4 canonical: enable → owned" \
	|| bad "L4 canonical enable state"
# --- L2: set-luci-login wraps rpcd mutations in um_tx_* (#106) ---

printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"
um_with_lock um_mut_set_luci_login ops enable
[ "$(um_luci_login_state ops)" = "owned" ] || bad "L2 pre: owned"
# Simulate crash mid-disable: begin tx, mutate, rollback without commit.
_before=$(cat "$USRMANAGE_RPCD_CONFIG")
um_tx_begin
printf 'config rpcd\n\toption socket /torn\n\n' > "$USRMANAGE_RPCD_CONFIG"
um_tx_rollback
_after=$(cat "$USRMANAGE_RPCD_CONFIG")
[ "$_before" = "$_after" ] && ok "L2 tx rollback restores prior rpcd" \
	|| bad "L2 rollback did not restore rpcd"
grep -q 'um_tx_begin' "$USRMANAGE_LIB_DIR/usrmanage-luci-login.sh" \
	&& grep -q 'um_tx_commit' "$USRMANAGE_LIB_DIR/usrmanage-luci-login.sh" \
	&& ok "L2 um_mut_set_luci_login uses um_tx_*" \
	|| bad "L2 missing um_tx wrap in set-luci-login"

[ "$fail" = "0" ] || exit 1
echo "luci-login tests: ok"
