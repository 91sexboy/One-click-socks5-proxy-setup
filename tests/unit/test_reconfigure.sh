#!/bin/sh
# tests/unit/test_reconfigure.sh - in-place configuration transaction and lock.

S5T_NAME=test_reconfigure
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

OLD_USER=olduser
OLD_PASS='OldPassword_1234'
OLD_PORT=41080
NEW_USER=newuser
NEW_PASS='NewPassword_1234'
NEW_PORT=41081

# The complete default path accepts Enter for confirmation, port, username and
# password in one installation, then persists mutually consistent values.
mkdir -p "$S5_UNITDIR"
rm -f "$S5_TEST_ROOT/expected_creds"
s5env_install_cli '' '' '' '' ''
t_run env -u S5_LIB_ONLY sh "$S5_SRC" install <"$S5_TEST_ROOT/answers"
assert_eq "all-default installation succeeds" 0 "$T_STATUS"
s5_state_load
_default_port=$(s5_state_get port)
_default_user=$(s5_state_get username)
_default_line=$(cat "$S5_USERSCFG")
case "$_default_port" in
'' | *[!0-9]*) t_bad "default port is not numeric: [$_default_port]" ;;
*) if [ "$_default_port" -ge 20000 ] && [ "$_default_port" -le 60000 ]; then t_ok; else t_bad "default port is outside 20000-60000"; fi ;;
esac
case "$_default_user" in
[a-z][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9][a-z0-9]) t_ok ;;
*) t_bad "default username has the wrong shape: [$_default_user]" ;;
esac
_default_password=${_default_line#*:CL:}
assert_eq "default credential username matches state" "$_default_user" "${_default_line%%:CL:*}"
assert_eq "default password is exactly 32 characters" 32 "${#_default_password}"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_eq "default installation can be removed cleanly" 0 "$T_STATUS"

mkdir -p "$S5_UNITDIR"
printf '%s:%s' "$OLD_USER" "$OLD_PASS" >"$S5_TEST_ROOT/expected_creds"
s5env_install_answers y "$OLD_PORT" "$OLD_USER" "$OLD_PASS"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "fixture install succeeds" 0 "$T_STATUS"
_old_bin=$(sha256sum "$S5_BIN" | cut -d' ' -f1)
_old_unit=$(sha256sum "$S5_UNIT" | cut -d' ' -f1)

# Enter at the default-no confirmation changes nothing.
s5env_reset_transcript
_before_users=$(cat "$S5_USERSCFG")
_before_cfg=$(cat "$S5_CFG")
_before_state=$(cat "$S5_STATE")
s5env_answers '
'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "default-no reconfiguration succeeds without changing state" 0 "$T_STATUS"
assert_contains "the current port is shown before confirmation" "$OLD_PORT" "$T_OUT"
assert_contains "the current username is shown before confirmation" "$OLD_USER" "$T_OUT"
assert_eq "cancel keeps credentials byte-for-byte" "$_before_users" "$(cat "$S5_USERSCFG")"
assert_eq "cancel keeps config byte-for-byte" "$_before_cfg" "$(cat "$S5_CFG")"
assert_eq "cancel keeps state byte-for-byte" "$_before_state" "$(cat "$S5_STATE")"
t_assert_never_called "cancel does not restart the service" 'systemctl start'
assert_file_absent "cancel leaves no transaction" "$S5_TXNDIR"
assert_file_absent "cancel releases the operation lock" "$S5_LOCKDIR"

# A confirmed port and credential change reuses the binary, account and unit.
s5env_reset_transcript
printf '%s:%s' "$NEW_USER" "$NEW_PASS" >"$S5_TEST_ROOT/expected_creds"
s5env_install_answers y "$NEW_PORT" "$NEW_USER" "$NEW_PASS"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "confirmed reconfiguration succeeds" 0 "$T_STATUS"
assert_eq "new credential is installed" "$NEW_USER:CL:$NEW_PASS" "$(cat "$S5_USERSCFG")"
assert_contains "state records the new port" "port	$NEW_PORT" "$(cat "$S5_STATE")"
assert_contains "state records the new username" "username	$NEW_USER" "$(cat "$S5_STATE")"
assert_contains "config listens on the new port" "-p$NEW_PORT" "$(cat "$S5_CFG")"
assert_eq "binary is reused" "$_old_bin" "$(sha256sum "$S5_BIN" | cut -d' ' -f1)"
assert_eq "service definition is reused" "$_old_unit" "$(sha256sum "$S5_UNIT" | cut -d' ' -f1)"
t_assert_never_called "reconfiguration does not rebuild 3proxy" 'make -f'
t_assert_never_called "reconfiguration does not recreate the account" 'useradd'
t_assert_never_called "reconfiguration does not enable the service again" 'systemctl enable'
t_assert_cmd_never_called "reconfiguration never touches a firewall" iptables ufw firewall-cmd nft
assert_eq "service now listens on the new port" "$NEW_PORT" "$(cat "$S5_TEST_ROOT/svc_active")"
assert_file_absent "successful reconfiguration removes its transaction" "$S5_TXNDIR"
assert_file_absent "successful reconfiguration releases its lock" "$S5_LOCKDIR"
assert_not_contains "redirected result does not reveal the password" "$NEW_PASS" "$T_OUT"
assert_contains "redirected result explains why credentials are hidden" "not displayed" "$T_OUT"

# Reusing the current port is allowed because preflight proves this project owns
# the active listener; credentials can still rotate in place.
SAME_USER=sameport
SAME_PASS='SamePortPass_1234'
s5env_reset_transcript
printf '%s:%s' "$SAME_USER" "$SAME_PASS" >"$S5_TEST_ROOT/expected_creds"
s5env_install_answers y "$NEW_PORT" "$SAME_USER" "$SAME_PASS"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "same-port credential rotation succeeds" 0 "$T_STATUS"
assert_eq "same-port rotation writes the new credential" \
    "$SAME_USER:CL:$SAME_PASS" "$(cat "$S5_USERSCFG")"
assert_eq "same-port rotation keeps the listener" "$NEW_PORT" "$(cat "$S5_TEST_ROOT/svc_active")"

# If the new valid-credential probe fails, the old files and running proxy are
# restored and verified. Keeping expected_creds on the old value makes only the
# candidate good-credential check fail in the deterministic curl stub.
ROLL_USER=rollbackuser
ROLL_PASS='RollbackPass_1234'
ROLL_PORT=41082
_before_users=$(cat "$S5_USERSCFG")
_before_cfg=$(cat "$S5_CFG")
_before_state=$(cat "$S5_STATE")
s5env_reset_transcript
# expected_creds deliberately remains SAME_USER:SAME_PASS
s5env_install_answers y "$ROLL_PORT" "$ROLL_USER" "$ROLL_PASS"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "failed candidate returns nonzero" 0 "$T_STATUS"
assert_contains "failed candidate announces restoration" "restoring" "$T_OUT"
assert_contains "old proxy is verified after restoration" "restored and verified" "$T_OUT"
assert_eq "rollback restores credentials byte-for-byte" "$_before_users" "$(cat "$S5_USERSCFG")"
assert_eq "rollback restores config byte-for-byte" "$_before_cfg" "$(cat "$S5_CFG")"
assert_eq "rollback restores state byte-for-byte" "$_before_state" "$(cat "$S5_STATE")"
assert_eq "old port listens after rollback" "$NEW_PORT" "$(cat "$S5_TEST_ROOT/svc_active")"
assert_file_absent "successful rollback removes its transaction" "$S5_TXNDIR"
assert_file_absent "failed candidate still releases its lock" "$S5_LOCKDIR"
assert_not_contains "rollback output does not reveal candidate password" "$ROLL_PASS" "$T_OUT"
assert_not_contains "rollback output does not reveal restored password" "$SAME_PASS" "$T_OUT"

# A foreign listener blocks a requested new port before a transaction is made.
s5env_reset_transcript
printf '%s\n' 41083 >"$S5_TEST_ROOT/occupied"
s5env_answers 'y
41083
'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "occupied replacement port is refused" 0 "$T_STATUS"
assert_contains "occupied replacement port is named" "already in use" "$T_OUT"
assert_file_absent "rejected input creates no transaction" "$S5_TXNDIR"
assert_eq "rejected input keeps old credentials" "$_before_users" "$(cat "$S5_USERSCFG")"
: >"$S5_TEST_ROOT/occupied"

# If the service cannot be proved stopped, final files stay untouched and the
# recovery bundle remains until a later mutation can verify restoration.
s5env_reset_transcript
: >"$S5_TEST_ROOT/stub_stop_leaves_active"
s5env_install_answers y 41085 blockeduser 'BlockedPass_1234'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "unverifiable stop rejects reconfiguration" 0 "$T_STATUS"
assert_dir_exists "failed recovery keeps its transaction" "$S5_TXNDIR"
assert_file_absent "failed recovery still releases its lock" "$S5_LOCKDIR"
assert_eq "unverifiable stop leaves credentials untouched" "$_before_users" "$(cat "$S5_USERSCFG")"
rm -f "$S5_TEST_ROOT/stub_stop_leaves_active"
t_run s5_with_mutation_lock :
assert_eq "a later mutation completes the retained recovery" 0 "$T_STATUS"
assert_file_absent "later recovery removes its transaction" "$S5_TXNDIR"

# A crash-shaped armed transaction is recovered before the next mutation.
CRASH_USER=crashuser
CRASH_PASS='CrashPass_1234'
CRASH_PORT=41084
S5_PORT=$CRASH_PORT
S5_USERNAME=$CRASH_USER
S5_PASSWORD=$CRASH_PASS
S5_SECRET=$CRASH_PASS
t_run _s5_reconfigure_stage
assert_eq "an interrupted transaction can be armed" 0 "$T_STATUS"
assert_mode "transaction directory is private" 700 "$S5_TXNDIR"
assert_mode "candidate credentials stay protected" 640 "$S5_TXN_NEW_USERS"
assert_mode "candidate config stays private" 600 "$S5_TXN_NEW_CFG"
assert_mode "credential backup stays private" 600 "$S5_TXN_OLD_USERS"
assert_mode "state backup stays private" 600 "$S5_TXN_OLD_STATE"
s5_service_stop >/dev/null 2>&1
_s5_copy_file_secure "$S5_TXN_NEW_USERS" "$S5_USERSCFG" "root:$S5_SERVICE_GROUP" 0640
_s5_copy_file_secure "$S5_TXN_NEW_CFG" "$S5_CFG" "root:$S5_SERVICE_GROUP" 0640
s5_state_load
s5_state_replace_identity "$CRASH_PORT" "$CRASH_USER"
printf '%s:%s' "$SAME_USER" "$SAME_PASS" >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_status
assert_ne "status refuses a potentially mixed transaction" 0 "$T_STATUS"
t_run s5_cmd_show
assert_ne "show refuses a potentially mixed transaction" 0 "$T_STATUS"
assert_not_contains "blocked show reveals no old password" "$SAME_PASS" "$T_OUT"
t_run s5_with_mutation_lock :
assert_eq "the next mutation recovers an armed transaction" 0 "$T_STATUS"
assert_eq "pending recovery restores credentials" "$_before_users" "$(cat "$S5_USERSCFG")"
assert_eq "pending recovery restores config" "$_before_cfg" "$(cat "$S5_CFG")"
assert_eq "pending recovery restores state" "$_before_state" "$(cat "$S5_STATE")"
assert_eq "pending recovery restarts the old port" "$NEW_PORT" "$(cat "$S5_TEST_ROOT/svc_active")"
assert_file_absent "pending recovery removes its transaction" "$S5_TXNDIR"
assert_file_absent "pending recovery releases its lock" "$S5_LOCKDIR"

# Uninstall can recover the old files without requiring the external good-auth
# probe, so an egress outage cannot trap the operator in an installed state.
S5_PORT=41086
S5_USERNAME=removeuser
S5_PASSWORD='RemovePass_1234'
S5_SECRET=$S5_PASSWORD
_s5_reconfigure_stage >/dev/null 2>&1
s5_service_stop >/dev/null 2>&1
_s5_copy_file_secure "$S5_TXN_NEW_USERS" "$S5_USERSCFG" "root:$S5_SERVICE_GROUP" 0640
_s5_copy_file_secure "$S5_TXN_NEW_CFG" "$S5_CFG" "root:$S5_SERVICE_GROUP" 0640
s5_state_load
s5_state_replace_identity "$S5_PORT" "$S5_USERNAME"
: >"$S5_TEST_ROOT/stub_curl_all_fail"
s5env_answers 'y
'
t_run s5_cmd_uninstall <"$S5_TEST_ROOT/answers"
assert_eq "uninstall is not blocked by recovery egress" 0 "$T_STATUS"
assert_file_absent "uninstall removes the transaction" "$S5_TXNDIR"
assert_file_absent "uninstall removes state" "$S5_STATE"
rm -f "$S5_TEST_ROOT/stub_curl_all_fail"

# A phase-less directory left during lock-safe staging is known to precede any
# final-file replacement and can be cleaned automatically.
mkdir -p "$S5_TXNDIR"
printf 'partial\n' >"$S5_TXNDIR/.s5copy.partial"
t_run s5_with_mutation_lock :
assert_eq "a phase-less staging directory self-heals" 0 "$T_STATUS"
assert_file_absent "phase-less cleanup removes the transaction" "$S5_TXNDIR"

# The lock rejects a live owner and removes a provably stale owner once.
mkdir -p "${S5_LOCKDIR%/*}" "$S5_LOCKDIR"
_live_boot=$(s5_boot_id)
_live_start=$(s5_process_start_id "$$")
printf '%s\n%s\n%s\n' "$$" "$_live_boot" "$_live_start" >"$S5_LOCK_OWNER"
chmod 0600 "$S5_LOCK_OWNER"
t_run s5_cmd_status
assert_ne "status does not race a live mutation" 0 "$T_STATUS"
assert_contains "status reports the live mutation lock" "PID $$" "$T_OUT"
t_run s5_cmd_show
assert_ne "show does not race a live mutation" 0 "$T_STATUS"
assert_not_contains "locked show reveals no password" "$SAME_PASS" "$T_OUT"
t_run s5_lock_acquire
assert_ne "a live mutation lock is refused" 0 "$T_STATUS"
assert_contains "live lock reports its owner" "PID $$" "$T_OUT"

s5_process_state() { printf Z; }
s5_lock_acquire >"$S5_TEST_ROOT/lock.out" 2>&1
_lock_rc=$?
assert_eq "a zombie lock owner is treated as stale" 0 "$_lock_rc"
s5_lock_release >/dev/null 2>&1

mkdir "$S5_LOCKDIR"
printf '%s\n%s\n%s\n' 99999999 "$_live_boot" 1 >"$S5_LOCK_OWNER"
chmod 0600 "$S5_LOCK_OWNER"
s5_lock_acquire >"$S5_TEST_ROOT/lock.out" 2>&1
_lock_rc=$?
assert_eq "a provably stale lock is replaced" 0 "$_lock_rc"
assert_eq "replacement lock belongs to this process" 1 "$S5_LOCK_HELD"
s5_lock_release >"$S5_TEST_ROOT/unlock.out" 2>&1
_unlock_rc=$?
assert_eq "replacement lock can be released" 0 "$_unlock_rc"
assert_file_absent "released stale lock leaves no directory" "$S5_LOCKDIR"

mkdir "$S5_LOCKDIR"
s5_lock_acquire >"$S5_TEST_ROOT/lock.out" 2>&1
_lock_rc=$?
assert_eq "an ownerless interrupted lock self-heals" 0 "$_lock_rc"
s5_lock_release >/dev/null 2>&1
assert_file_absent "ownerless lock recovery leaves no directory" "$S5_LOCKDIR"

mkdir "$S5_LOCKDIR"
printf 'partial\n' >"$S5_LOCK_OWNER"
s5_lock_acquire >"$S5_TEST_ROOT/lock.out" 2>&1
_lock_rc=$?
assert_eq "a partial owner record self-heals" 0 "$_lock_rc"
s5_lock_release >/dev/null 2>&1
assert_file_absent "partial lock recovery leaves no directory" "$S5_LOCKDIR"

S5_PASSWORD=''
S5_SECRET=''
t_summary
