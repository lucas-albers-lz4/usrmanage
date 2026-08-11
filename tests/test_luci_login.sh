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
export USRMANAGE_DRY_RUN=1
export USRMANAGE_SRC=cli
export USRMANAGE_ACTOR=testhost
export USRMANAGE_TEST_OVERRIDES=1
export JSON_OUT=0

mkdir -p "$USRMANAGE_ETC" "$USRMANAGE_AUDIT_DIR" "$(dirname "$USRMANAGE_LOCK")"
touch "$USRMANAGE_REGISTRY" "$USRMANAGE_AUDIT"
# Usable shadow hash (not empty / locked) — C1 gate
printf 'root:x:0:0:root:/root:/bin/ash\nops:x:1002:1002:ops:/home/ops:/bin/ash\naudit:x:1001:1001:audit:/home/audit:/bin/ash\nempty:x:1003:1003:empty:/home/empty:/bin/ash\n' > "$USRMANAGE_PASSWD"
printf 'root:$6$salt$hash:0:99999:7:::\nops:$6$salt$ophash:0:99999:7:::\naudit:$6$salt$auhash:0:99999:7:::\nempty::0:99999:7:::\n' > "$USRMANAGE_SHADOW"
printf 'root:x:0:\nwheel:x:10:ops\n' > "$USRMANAGE_GROUP"
printf 'ops\naudit\nempty\n' > "$USRMANAGE_REGISTRY"
printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$USRMANAGE_SUDOERS"
printf 'config rpcd\n\toption socket /var/run/ubus/ubus.sock\n\n' > "$USRMANAGE_RPCD_CONFIG"

# shellcheck disable=SC1090
. "$LIB"

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
printf 'ops\naudit\nempty\n' > "$USRMANAGE_REGISTRY"
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

[ "$fail" = "0" ] || exit 1
echo "luci-login tests: ok"
