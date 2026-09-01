#!/bin/sh
# tests/unit/test_install.sh - Task 6: install flow, atomic writes, state file,
# firewall handling, self-test, failure cleanup, idempotency.
#
# Nothing real is touched: every privileged command is a recording stub and all
# paths live under $S5_TEST_ROOT.

S5T_NAME=test_install
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

USER_OK=gooduser
PASS_OK='TestPassword_123~x'
printf '%s:%s' "$USER_OK" "$PASS_OK" >"$S5_TEST_ROOT/expected_creds"

# ==========================================================================
# State file
# ==========================================================================
S5_PORT=31080
S5_USERNAME=$USER_OK
S5_PASSWORD=$PASS_OK

s5_state_begin >/dev/null 2>&1
assert_eq "state file created" 0 "$?"
assert_file_exists "state file exists" "$S5_STATE"
assert_mode "state file is 0600" 600 "$S5_STATE"

s5_state_mark created_confdir
s5_state_add port 31080
assert_eq "new state records release-asset origin" release-asset "$(s5_state_get origin)"
assert_eq "new state records the selected asset" "$S5_ASSET_NAME" "$(s5_state_get asset)"
assert_eq "new state records the embedded digest" "$S5_ASSET_SHA256" "$(s5_state_get sha256)"
if s5_state_flagged created_confdir; then t_ok; else t_bad "flag should be recorded"; fi
if s5_state_flagged created_bin; then t_bad "unset flag must not read as set"; else t_ok; fi
assert_eq "state records the port" 31080 "$(s5_state_get port)"
# the state file records FLAGS, never paths to delete
if grep -q "$S5_SYSCONFDIR" "$S5_STATE"; then
    t_bad "the state file must not contain deletable paths"
else
    t_ok
fi
assert_not_contains "state file never contains the password" "$PASS_OK" "$(cat "$S5_STATE")"
rm -rf "$S5_STATEDIR"

# ==========================================================================
# Atomic write
# ==========================================================================
mkdir -p "$S5_SYSCONFDIR"
printf 'hello world\n' | s5_atomic_write "$S5_SYSCONFDIR/t1" "root:root" 0640
assert_file_exists "atomic write created the file" "$S5_SYSCONFDIR/t1"
assert_mode "atomic write applied the mode" 640 "$S5_SYSCONFDIR/t1"
assert_eq "atomic write wrote the content" "hello world" "$(cat "$S5_SYSCONFDIR/t1")"
leftovers=$(find "$S5_SYSCONFDIR" -name '.s5tmp.*' | grep -c . || true)
assert_eq "no temporary file left behind" 0 "$leftovers"

# rewriting leaves no untracked backup file behind
printf 'second\n' | s5_atomic_write "$S5_SYSCONFDIR/t1" "root:root" 0640
assert_eq "content replaced" "second" "$(cat "$S5_SYSCONFDIR/t1")"
baks=$(find "$S5_SYSCONFDIR" -name 't1.bak-*' | grep -c . || true)
assert_eq "no untracked backup file is created" 0 "$baks"

# a write into a missing directory fails rather than creating a partial tree
t_run s5_atomic_write "$S5_TEST_ROOT/nope/deeper/f" "root:root" 0640
assert_ne "write to a missing directory fails" 0 "$T_STATUS"
assert_file_absent "no partial path created" "$S5_TEST_ROOT/nope"
rm -rf "$S5_SYSCONFDIR"

# A path can be rebound after no-replace publication but before the ownership
# flag is persisted. Handoff must revalidate the pending inode and refuse to
# record the replacement as project-owned.
rm -rf "$S5_STATEDIR" "$S5_SYSCONFDIR"
s5_state_begin >/dev/null 2>&1
mkdir -p "$S5_SYSCONFDIR"
s5_publish_new_text "$S5_CFG" "root:root" 0640 'ours' >/dev/null 2>&1
rm -f "$S5_CFG"
printf 'foreign replacement\n' >"$S5_CFG"
_replacement_id=$(stat -c '%d:%i' "$S5_CFG")
t_run s5_state_mark_claim created_cfg
assert_ne "claim handoff rejects a path rebound after publication" 0 "$T_STATUS"
if s5_state_flagged created_cfg; then
    t_bad "a rebound path must not receive a durable ownership flag"
else
    t_ok
fi
assert_eq "the replacement survives rejected handoff" \
    "foreign replacement" "$(cat "$S5_CFG")"
assert_eq "the replacement inode is unchanged after rejected handoff" \
    "$_replacement_id" "$(stat -c '%d:%i' "$S5_CFG")"
s5_pending_claim_clear
rm -rf "$S5_STATEDIR" "$S5_SYSCONFDIR"

# ==========================================================================
# Static configuration check
# ==========================================================================
mkdir -p "$S5_SYSCONFDIR"
s5_render_cfg >"$S5_CFG"
s5_render_users >"$S5_USERSCFG"
chmod 0640 "$S5_USERSCFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_eq "a correctly rendered config passes the static check" 0 "$T_STATUS"

# missing required directive
grep -v '^auth strong$' "$S5_CFG" >"$S5_TEST_ROOT/bad1"
t_run s5_static_check_cfg "$S5_TEST_ROOT/bad1"
assert_ne "missing auth strong is rejected" 0 "$T_STATUS"
assert_contains "names the missing directive" "auth strong" "$T_OUT"

# missing terminal deny
grep -v '^deny \*$' "$S5_CFG" >"$S5_TEST_ROOT/bad2"
t_run s5_static_check_cfg "$S5_TEST_ROOT/bad2"
assert_ne "missing terminal deny is rejected" 0 "$T_STATUS"

# forbidden directives
for bad in "admin" "proxy -p3128" "socks -p1080" "writable" "system ls" "plugin x" "parent 1000 socks5 1.2.3.4 1080" "authcache ip 60" "setuid 65534" "setgid 65534"; do
    cp "$S5_CFG" "$S5_TEST_ROOT/bad3"
    printf '%s\n' "$bad" >>"$S5_TEST_ROOT/bad3"
    t_run s5_static_check_cfg "$S5_TEST_ROOT/bad3"
    assert_ne "forbidden directive rejected: $bad" 0 "$T_STATUS"
done

# forbidden protocol capabilities
for bad in "auth none" "auth iponly" "allow gooduser * * * BIND" "allow gooduser * * * UDPASSOC"; do
    cp "$S5_CFG" "$S5_TEST_ROOT/bad4"
    printf '%s\n' "$bad" >>"$S5_TEST_ROOT/bad4"
    t_run s5_static_check_cfg "$S5_TEST_ROOT/bad4"
    assert_ne "forbidden capability rejected: $bad" 0 "$T_STATUS"
done

# credentials file must be referenced and correctly protected
chmod 0644 "$S5_USERSCFG"
t_run s5_static_check_cfg "$S5_CFG"
assert_ne "world-readable credentials file is rejected" 0 "$T_STATUS"
chmod 0640 "$S5_USERSCFG"
rm -rf "$S5_SYSCONFDIR"

# ==========================================================================
# No firewall functionality at all (owner decision, round 12). Round 10
# deleted the mutating half; this decision removes the read-only remnant
# (detect / manual hint / guidance) too. Not one firewall function name may
# appear in socks5.sh, and the install step must reference nothing firewall-
# related -- detection included, since even a read-only query is functionality
# the owner asked to drop.
# ==========================================================================
for _gone in s5_maybe_open_firewall s5_firewall_open s5_firewall_close \
    s5_firewall_rule_still_there s5_ufw_rule_present s5_iptables_rule_present \
    s5_firewalld_zone s5_firewall_detect s5_firewall_manual_hint \
    s5_firewall_guidance S5_FW_ZONE; do
    if grep -q "$_gone" "${S5_SRC}"; then
        t_bad "firewall functionality is present again: $_gone"
    else
        t_ok
    fi
done
for _key in 'firewall_zone' 'state_add firewall'; do
    if grep -q "$_key" "${S5_SRC}"; then
        t_bad "a firewall state key is back: $_key"
    else
        t_ok
    fi
done
fw_steps=$(sed -n '/^s5_install_steps() {/,/^}/p' "${S5_SRC}" | grep -v '^[[:space:]]*#')
if printf '%s\n' "$fw_steps" | grep -q 'firewall'; then
    t_bad "the install step still references firewall functionality"
else
    t_ok
fi

# ==========================================================================
# Self-test: credentials travel on stdin only
# ==========================================================================
s5env_reset_transcript
S5_PORT=31080
t_run s5_selftest_good "$USER_OK" "$PASS_OK"
assert_eq "correct credentials pass the self-test" 0 "$T_STATUS"
t_assert_called "curl ignores curlrc and reads config from stdin" 'curl -q --config -'
t_assert_no_secret_in_argv "password never appears in curl argv" "$PASS_OK"
assert_contains "stdin carried the proxy user" "proxy-user" "$(cat "$S5_TEST_ROOT/curl_stdin")"
assert_contains "stdin carried the fixed self-test URL" "https://example.com/" "$(cat "$S5_TEST_ROOT/curl_stdin")"

s5env_reset_transcript
t_run s5_selftest_bad "$USER_OK" "$PASS_OK"
assert_eq "wrong credentials are rejected, which is a pass" 0 "$T_STATUS"
assert_contains "bad-password probe uses the configured username" \
    "proxy-user = \"$USER_OK:" "$(cat "$S5_TEST_ROOT/curl_stdin")"
assert_not_contains "bad-password probe never retries the correct credential" \
    "proxy-user = \"$USER_OK:$PASS_OK\"" "$(cat "$S5_TEST_ROOT/curl_stdin")"
t_assert_called "bad-password probe ignores curlrc" 'curl -q --config -'
t_assert_no_secret_in_argv "bad-credential probe leaks nothing either" "$PASS_OK"

# if a wrong password were accepted, the check must fail
s5env_reset_transcript
: >"$S5_TEST_ROOT/stub_curl_accept_all"
t_run s5_selftest_bad "$USER_OK" "$PASS_OK"
assert_ne "accepting bad credentials fails the check" 0 "$T_STATUS"
assert_contains "accepting bad credentials is reported as a security failure" "SECURITY" "$T_OUT"
rm -f "$S5_TEST_ROOT/stub_curl_accept_all"

# ...and a failure that is NOT a proxy handshake error proves nothing about
# authentication, so it must be reported as inconclusive rather than as a pass.
# Only curl 97 (CURLE_PROXY) shows the proxy itself rejected the credential; 7
# is a plain connect failure, which is what a real host gives when the listen
# address is wrong, a firewall is in the way, or the proxy died a second after
# starting. Before this case existed the curl stub could emit only 0 or 97 on
# this path, so the discrimination had no input and simplifying it to
# `if [ "$_strc" -eq 0 ]` left the whole suite green.
for badcode in 7 6 28 35; do
    s5env_reset_transcript
    printf '%s\n' "$badcode" >"$S5_TEST_ROOT/stub_curl_code"
    t_run s5_selftest_bad "$USER_OK" "$PASS_OK"
    assert_ne "curl $badcode is not accepted as proof of rejection" 0 "$T_STATUS"
    assert_contains "curl $badcode is reported as inconclusive" "inconclusive" "$T_OUT"
    assert_contains "curl $badcode names the status it saw" "$badcode" "$T_OUT"
    assert_not_contains "curl $badcode is never called a refusal" "correctly refused" "$T_OUT"
    rm -f "$S5_TEST_ROOT/stub_curl_code"
done

# The boundary itself: 97 is the one code that does count.
s5env_reset_transcript
printf '97\n' >"$S5_TEST_ROOT/stub_curl_code"
t_run s5_selftest_bad "$USER_OK" "$PASS_OK"
assert_eq "curl 97 is accepted as proof the proxy refused" 0 "$T_STATUS"
rm -f "$S5_TEST_ROOT/stub_curl_code"

# Failure classification is a four-way decision. Keep it independent from the
# curl stub so every branch has a direct, falsifiable input.
diagnose_case() (
    _dc_egress=$1
    _dc_dns=$2
    s5_direct_egress_ok() { return "$_dc_egress"; }
    s5_dns_ok() { return "$_dc_dns"; }
    s5_diagnose_failure
)
assert_eq "DNS failure is classified" dns-failure "$(diagnose_case 6 1)"
assert_eq "generic transport failure with DNS is no egress" no-egress "$(diagnose_case 7 0)"
assert_eq "HTTP failure from the fixed endpoint is external service" \
    external-service-failure "$(diagnose_case 22 0)"
assert_eq "direct egress success leaves the proxy as the failing component" \
    proxy-failure "$(diagnose_case 0 0)"

curl_cfg=$(s5_curl_config "$USER_OK" "$PASS_OK")
assert_contains "proxy self-test treats HTTP errors as failure" "fail" "$curl_cfg"
direct_fn=$(sed -n '/^s5_direct_egress_ok() {/,/^}/p' "$S5_SRC")
assert_contains "direct diagnosis treats HTTP errors as failure" "-fsS" "$direct_fn"
assert_contains "direct diagnosis ignores curlrc" "curl -q" "$direct_fn"

S5_LANG=en
t_run s5_explain_failure external-service-failure
assert_contains "English explains an external self-test outage without blaming the proxy" \
    "does not prove the proxy itself is faulty" "$T_OUT"
S5_LANG=zh
t_run s5_explain_failure external-service-failure
assert_contains "Chinese explains an external self-test outage without blaming the proxy" \
    "不能证明代理本身有故障" "$T_OUT"
S5_LANG=en

# ==========================================================================
# Full install
# ==========================================================================
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX" "$S5_UNITDIR"
rm -f "$S5_TEST_ROOT/svc_active"
mkdir -p "$S5_UNITDIR"
s5env_install_answers y 31080 gooduser 'TestPassword_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "install succeeds" 0 "$T_STATUS"
assert_file_exists "config written" "$S5_CFG"
assert_file_exists "credentials written" "$S5_USERSCFG"
assert_file_exists "binary installed" "$S5_BIN"
assert_file_exists "unit written" "$S5_UNIT"
assert_file_exists "state written" "$S5_STATE"
assert_mode "config dir is 0750" 750 "$S5_SYSCONFDIR"
assert_mode "config is 0640" 640 "$S5_CFG"
assert_mode "credentials are 0640" 640 "$S5_USERSCFG"
assert_mode "state is 0600" 600 "$S5_STATE"
assert_eq "credential line is correct" "gooduser:CL:TestPassword_123~x" "$(cat "$S5_USERSCFG")"

# the service must never be started before the config and unit exist
startline=$(s5env_line_of 'systemctl start')
if [ "$startline" -gt 0 ]; then t_ok; else t_bad "service was never started"; fi
if t_transcript | grep -q 'systemctl start.*cfgpresent=yes unitpresent=yes'; then
    t_ok
else
    t_bad "3proxy was started before the config/unit were in place"
fi
enableline=$(s5env_line_of 'systemctl enable')
if [ "$enableline" -lt "$startline" ]; then t_ok; else t_bad "enable should precede start"; fi

# account was created, with no password, and no package was removed
t_assert_called "service account created" 'useradd'
t_assert_cmd_never_called "no password ever set on the service account" passwd chpasswd
t_assert_never_called "no package removal during install" 'apt-get remove'
t_assert_cmd_never_called "no sudo" sudo doas
t_assert_no_secret_in_argv "no stub ever saw the password in argv" "$PASS_OK"

# state records what was created; never the secret
s5_state_load >/dev/null 2>&1
st=$(cat "$S5_STATE")
assert_contains "state records the port" "31080" "$st"
assert_contains "state records the username" "gooduser" "$st"
assert_contains "state marks completion" "complete" "$st"
for f in created_account created_prefix created_bin created_confdir created_cfg created_users created_unit; do
    if s5_state_flagged "$f"; then t_ok; else t_bad "missing flag: $f"; fi
done
if grep -qE "	/" "$S5_STATE"; then t_bad "state must not record absolute paths"; else t_ok; fi
assert_not_contains "state has no password" "$PASS_OK" "$st"

# no log sink ever receives the password
if [ -f "${S5_LOGSINK:-/dev/null}" ]; then
    assert_not_contains "log sink has no password" "$PASS_OK" "$(cat "$S5_LOGSINK")"
else
    t_ok
fi

# ==========================================================================
# Existing install: Enter safely cancels reconfiguration
# ==========================================================================
s5env_reset_transcript
before=$(cat "$S5_USERSCFG")
# The reconfiguration confirmation is default-no; no value prompts follow.
s5env_answers '
'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "default-no reconfiguration exits 0" 0 "$T_STATUS"
assert_contains "existing install offers an in-place update" "updated" "$T_OUT"
assert_contains "default-no reconfiguration is cancelled" "unchanged" "$T_OUT"
assert_eq "credentials remain untouched after cancellation" "$before" "$(cat "$S5_USERSCFG")"
t_assert_never_called "cancelled reconfiguration creates no account" 'useradd'
t_assert_never_called "cancelled reconfiguration rebuilds nothing" 'make -f'
users_lines=$(grep -c '' "$S5_USERSCFG")
assert_eq "still exactly one credential line" 1 "$users_lines"

# ==========================================================================
# Collision: an unattributable existing resource aborts before any write
# ==========================================================================
s5env_reset_transcript
rm -rf "$S5_STATEDIR"
: >"$S5_TEST_ROOT/foreign_marker"
t_run s5_collision_check
assert_ne "existing config dir with no state aborts" 0 "$T_STATUS"
assert_contains "collision message explains itself" "not created by this script" "$T_OUT"
t_assert_never_called "collision check writes nothing" 'useradd'

# A foreign fixed resource can appear after the advisory collision check while
# install waits for confirmation. The final create operation must claim the
# path exclusively rather than accepting the directory and replacing the file.
late_binary_race() (
    s5_confirm_yes() {
        read -r _late_answer || return 1
        mkdir -p "$S5_PREFIX"
        printf 'foreign binary\n' >"$S5_BIN"
        stat -c '%d:%i' "$S5_BIN" >"$S5_TEST_ROOT/foreign_binary_inode"
        return 0
    }
    s5_cmd_install <"$S5_TEST_ROOT/answers"
)

s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
mkdir -p "$S5_UNITDIR"
s5env_install_answers y 31086 raceuser 'RacePassword_123~x'
t_run late_binary_race
assert_ne "install rejects a binary appearing after the collision check" 0 "$T_STATUS"
assert_contains "the late binary is reported as a collision" "not created by this script" "$T_OUT"
assert_eq "the late binary content is unchanged" "foreign binary" "$(cat "$S5_BIN")"
assert_eq "the late binary inode is unchanged" \
    "$(cat "$S5_TEST_ROOT/foreign_binary_inode")" "$(stat -c '%d:%i' "$S5_BIN")"
t_assert_never_called "the late binary never reaches systemd service start" \
    'systemctl start'
t_assert_never_called "the late binary never reaches OpenRC service start" \
    'rc-service socks5-manager start'

late_confdir_race() (
    s5_confirm_yes() {
        read -r _late_answer || return 1
        mkdir -p "$S5_SYSCONFDIR"
        stat -c '%d:%i' "$S5_SYSCONFDIR" >"$S5_TEST_ROOT/foreign_confdir_inode"
        return 0
    }
    s5_cmd_install <"$S5_TEST_ROOT/answers"
)

s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
mkdir -p "$S5_UNITDIR"
s5env_install_answers y 31087 dirrace 'DirectoryRace_123~x'
t_run late_confdir_race
assert_ne "install rejects a config directory appearing after collision check" 0 "$T_STATUS"
assert_eq "the late config directory inode is unchanged" \
    "$(cat "$S5_TEST_ROOT/foreign_confdir_inode")" \
    "$(stat -c '%d:%i' "$S5_SYSCONFDIR")"
assert_file_absent "no credentials are written into the foreign directory" "$S5_USERSCFG"

late_unit_race() (
    s5_confirm_yes() {
        read -r _late_answer || return 1
        mkdir -p "$S5_UNITDIR"
        printf 'foreign unit\n' >"$S5_UNIT"
        stat -c '%d:%i' "$S5_UNIT" >"$S5_TEST_ROOT/foreign_unit_inode"
        return 0
    }
    s5_cmd_install <"$S5_TEST_ROOT/answers"
)

s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
mkdir -p "$S5_UNITDIR"
s5env_install_answers y 31088 unitrace 'UnitRacePass_123~x'
t_run late_unit_race
assert_ne "install rejects a unit appearing after collision check" 0 "$T_STATUS"
assert_eq "the late unit content is unchanged" "foreign unit" "$(cat "$S5_UNIT")"
assert_eq "the late unit inode is unchanged" \
    "$(cat "$S5_TEST_ROOT/foreign_unit_inode")" "$(stat -c '%d:%i' "$S5_UNIT")"
t_assert_never_called "the late unit is never enabled" 'systemctl enable'
t_assert_never_called "the late unit is never started" 'systemctl start'

# ==========================================================================
# Failure cleanup: service start fails -> this run's resources are removed,
# and a pre-planted foreign file survives
# ==========================================================================
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
mkdir -p "$S5_UNITDIR"
: >"$S5_TEST_ROOT/stub_start_fail"
s5env_install_answers y 31081 otheruser 'TestPassword_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "install fails when the service will not start" 0 "$T_STATUS"
assert_file_absent "config removed on rollback" "$S5_CFG"
assert_file_absent "credentials removed on rollback" "$S5_USERSCFG"
assert_file_absent "binary removed on rollback" "$S5_BIN"
assert_file_absent "unit removed on rollback" "$S5_UNIT"
assert_file_absent "config dir removed on rollback" "$S5_SYSCONFDIR"
t_assert_called "rollback deleted the account it created" 'userdel'
if s5_account_exists; then t_bad "account must be gone after rollback"; else t_ok; fi
t_assert_never_called "rollback removes no system package" 'apt-get remove'
t_assert_never_called "rollback purges nothing" 'apt-get purge'
assert_file_exists "unrelated foreign file survives" "$S5_TEST_ROOT/foreign_marker"
rm -f "$S5_TEST_ROOT/stub_start_fail"

# a failed self-test also rolls back
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
: >"$S5_TEST_ROOT/stub_curl_all_fail"
s5env_install_answers y 31082 thirduser 'TestPassword_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "install fails when the self-test fails" 0 "$T_STATUS"
assert_file_absent "config removed after self-test failure" "$S5_CFG"
assert_file_absent "binary removed after self-test failure" "$S5_BIN"
rm -f "$S5_TEST_ROOT/stub_curl_all_fail"

# A written unit is not active in systemd until daemon-reload succeeds. If the
# reload fails, enabling or starting may act on a stale manager definition, so
# installation must stop before either operation and roll the new file back.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
: >"$S5_TEST_ROOT/stub_daemon_reload_fail"
s5env_install_answers y 31084 reloaduser 'TestPassword_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "install fails when systemd cannot reload the unit" 0 "$T_STATUS"
assert_contains "daemon-reload failure is explained" "reload the systemd manager" "$T_OUT"
t_assert_never_called "reload failure never enables a stale unit" 'systemctl enable'
t_assert_never_called "reload failure never starts a stale unit" 'systemctl start'
assert_file_absent "unit is rolled back after reload failure" "$S5_UNIT"
assert_file_exists "state is retained when final reload cannot be verified" "$S5_STATE"
assert_contains "final reload failure is actionable" \
    "reload the systemd manager" "$T_OUT"
rm -f "$S5_TEST_ROOT/stub_daemon_reload_fail"

# A service-manager query that FAILS is not an observed inactive service. The
# install must still fail closed, but it must say which of the two it saw, or the
# operator debugs a stopped proxy that may in fact be running.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
: >"$S5_TEST_ROOT/stub_active_query_fail"
s5env_install_answers y 31085 queryuser 'TestPassword_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "install fails when the active state cannot be queried" 0 "$T_STATUS"
assert_contains "install names an unverified active state" "could not verify" "$T_OUT"
assert_not_contains "install does not call a query error an inactive service" \
    "is not active after start" "$T_OUT"
# Rollback cannot prove the service stopped either, so it must KEEP the resources
# and the state file rather than deleting things while a proxy may still be live.
assert_file_exists "state is retained for retry" "$S5_STATE"
assert_contains "the incomplete rollback is actionable" "retry" "$T_OUT"
rm -f "$S5_TEST_ROOT/stub_active_query_fail"
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"

# ==========================================================================
# Readiness wait (fix-plan Task 1, real-CI root cause A).
#
# tests/golden/socks5-manager.service is Type=simple: systemd marks the unit
# active the moment it forks the process, before any socket is bound, and
# rc-service still answers nonzero while an OpenRC service is "starting". The
# install verification used to probe the port exactly once, immediately, so a
# host that took even a moment to bind rolled back a perfectly good install:
#     [*] starting socks5-manager
#     [x] nothing is listening on port 41080
# The stubs resolved service-active and port-bound in the same instant, so no
# test could express the race. The harness now models it: svc_latebind N hides
# the port for the first N observations of that port while the service is
# already active (see tests/lib/env.sh), and svc_die_after N makes the service
# exit during the same window. Production tests must not sleep their way to
# the answer, so the delay is measured in probe observations, never seconds.
#
# These cases run before the F28 block below, which replaces the static check
# for good: a late-bind install has to pass the REAL static check, not the
# neutered one, or it would prove nothing about a shippable configuration.
# ==========================================================================

# --- The service's socket appears within the wait window: install SUCCEEDS.
# Old code: the single immediate probe saw a free port and rolled back.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX" "$S5_UNITDIR"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen" \
    "$S5_TEST_ROOT/svc_die_after" "$S5_TEST_ROOT/svc_isactive_count" \
    "$S5_TEST_ROOT/port_probe_count"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
mkdir -p "$S5_UNITDIR"
printf '3\n' >"$S5_TEST_ROOT/svc_latebind"
s5env_install_answers y 31087 lateuser 'TestPassword_123~x'
printf '%s:%s' lateuser 'TestPassword_123~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "install succeeds when the port binds within the wait window" 0 "$T_STATUS"
assert_file_exists "late-binding install keeps the config" "$S5_CFG"
assert_file_exists "late-binding install keeps the state" "$S5_STATE"
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen"

# --- The port never appears: install FAILS with a timeout diagnostic, and
# does NOT report the instant-absence message that used to roll back a good
# install, nor the dead-service message -- the service stayed active.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active" \
    "$S5_TEST_ROOT/svc_latebind_seen"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
printf '999\n' >"$S5_TEST_ROOT/svc_latebind"
s5env_install_answers y 31088 neveruser 'TestPassword_123~x'
printf '%s:%s' neveruser 'TestPassword_123~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "install fails when the port never binds" 0 "$T_STATUS"
assert_contains "the timeout names the port it waited for" "31088" "$T_OUT"
assert_contains "the timeout says how long it waited" "15" "$T_OUT"
assert_not_contains "a full window is not reported as an instant absence" \
    "nothing is listening on port 31088" "$T_OUT"
assert_not_contains "and not as a dead service either" "exited" "$T_OUT"
assert_file_absent "never-binding install rolls back the config" "$S5_CFG"
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen"

# --- The service goes inactive during the wait: install fails FAST, well
# before the whole window, provable from the probe counter.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active" \
    "$S5_TEST_ROOT/svc_latebind_seen" "$S5_TEST_ROOT/svc_isactive_count"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
printf '999\n' >"$S5_TEST_ROOT/svc_latebind"
printf '1\n' >"$S5_TEST_ROOT/svc_die_after"
: >"$S5_TEST_ROOT/port_probe_count"
s5env_install_answers y 31089 dieuser 'TestPassword_123~x'
printf '%s:%s' dieuser 'TestPassword_123~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "install fails when the service exits while starting" 0 "$T_STATUS"
assert_contains "the failure says the service exited" "exited" "$T_OUT"
assert_not_contains "a dead service is not reported as a plain timeout" \
    "not listening after" "$T_OUT"
_died_after=$(cat "$S5_TEST_ROOT/port_probe_count")
if [ -n "$_died_after" ] && [ "$_died_after" -lt 15 ]; then
    t_ok
else
    t_bad "the wait must stop early on a dead service, but ran $_died_after probes"
fi
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen" \
    "$S5_TEST_ROOT/svc_die_after" "$S5_TEST_ROOT/svc_isactive_count" \
    "$S5_TEST_ROOT/port_probe_count"

# --- Tri-state 2 (cannot observe) still fails closed immediately and is
# never retried into a false success. The probe is swapped for one that
# answers "cannot observe" (the "ss exists but fails" case): a wait loop that
# treats status 2 as "not yet listening" would poll the whole window and then
# fail with the wrong message.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
printf '2\n' >"$S5_TEST_ROOT/svc_latebind"
mkdir -p "$S5_UNITDIR"
_save_probe=$S5_PORT_PROBE
cat >"$S5_TEST_ROOT/bin/portprobe_failing" <<'FAILPROBE'
#!/bin/sh
# Counts like the real stub, then answers "cannot observe" -- but only once
# the service exists. The port prompt runs BEFORE the start and must still
# see a working probe, or the install would fail at the prompt and never
# reach the verification the case exists to exercise.
if [ -f "$S5_TEST_ROOT/port_probe_count" ]; then
    _n=$(cat "$S5_TEST_ROOT/port_probe_count" 2>/dev/null)
    case "$_n" in '' | *[!0-9]*) _n=0 ;; esac
    _n=$((_n + 1))
    printf '%s\n' "$_n" >"$S5_TEST_ROOT/port_probe_count"
fi
if [ -f "$S5_TEST_ROOT/svc_active" ]; then
    exit 2
fi
exit 0
FAILPROBE
chmod 0755 "$S5_TEST_ROOT/bin/portprobe_failing"
S5_PORT_PROBE="$S5_TEST_ROOT/bin/portprobe_failing"
export S5_PORT_PROBE
: >"$S5_TEST_ROOT/port_probe_count"
s5env_install_answers y 31090 obscureuser 'TestPassword_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "an unobservable listen state fails the install" 0 "$T_STATUS"
assert_contains "install says it could not verify the port" "cannot verify" "$T_OUT"
assert_not_contains "an unobservable state is never a dead service" "exited" "$T_OUT"
_obscount=$(cat "$S5_TEST_ROOT/port_probe_count")
if [ -n "$_obscount" ] && [ "$_obscount" -le 2 ]; then
    t_ok
else
    t_bad "cannot-observe must not be retried: $_obscount probes were run"
fi
S5_PORT_PROBE=$_save_probe
export S5_PORT_PROBE
rm -f "$S5_TEST_ROOT/bin/portprobe_failing" "$S5_TEST_ROOT/svc_latebind" \
    "$S5_TEST_ROOT/svc_latebind_seen" "$S5_TEST_ROOT/port_probe_count"

# --- OpenRC (alpine): the same race wearing a different hat. rc-service
# reports the service started while the socket is not bound yet, and
# "starting" is not inactive -- so the wait must not fail fast on it.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active" \
    "$S5_TEST_ROOT/svc_latebind_seen"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/alpine-3.20"
printf '2\n' >"$S5_TEST_ROOT/svc_latebind"
s5env_install_answers y 31091 alpuser 'TestPassword_123~x'
printf '%s:%s' alpuser 'TestPassword_123~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "openrc install succeeds when the port binds within the wait window" 0 "$T_STATUS"
assert_file_exists "openrc late-binding install keeps the init script" "$S5_INITSCRIPT"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/debian-12"
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen"

# --- OpenRC 0.53 transient (real CI, Alpine 3.20 only): with
# supervisor="supervise-daemon" the FIRST `rc-service <svc> start` can exit
# nonzero after printing " * WARNING: <svc> is already starting" while the
# service is genuinely on its way up -- the supervised daemon launched, the
# startup phase not finished. Newer OpenRC (Alpine 3.24) completes the same
# install, which is what pins this as a 0.53 classification problem, not a
# service problem: rc-service's exit status reports the start COMMAND, and
# only the manager's status answers for the SERVICE. The install must
# re-query and proceed when the service is active, then let the existing
# port wait cover the socket (svc_latebind models the bind delay).
# Modelled by svc_start_transient in tests/stubs/rc-service.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active" \
    "$S5_TEST_ROOT/svc_latebind_seen"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/alpine-3.20"
printf '2\n' >"$S5_TEST_ROOT/svc_latebind"
: >"$S5_TEST_ROOT/svc_start_transient"
s5env_install_answers y 31092 alptruser 'TestPassword_123~x'
printf '%s:%s' alptruser 'TestPassword_123~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "openrc install succeeds through the transient already-starting refusal" 0 "$T_STATUS"
assert_contains "the transient warning really fired" "already starting" "$T_OUT"
assert_file_exists "transient-start install keeps the init script" "$S5_INITSCRIPT"
assert_file_exists "transient-start install keeps the state" "$S5_STATE"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/debian-12"
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen" \
    "$S5_TEST_ROOT/svc_start_transient"

# --- The same warning and the same nonzero exit, but the service never
# comes up: only the status re-query can tell this apart from the transient,
# so a classifier keying on the warning text or the exit code alone would
# pass this off as a success. The install must fail with the existing
# message and roll back, exactly as it did before the transient existed.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/alpine-3.20"
: >"$S5_TEST_ROOT/svc_start_transient_fail"
s5env_install_answers y 31093 alpdead 'TestPassword_123~x'
printf '%s:%s' alpdead 'TestPassword_123~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "openrc install fails when a warned start genuinely fails" 0 "$T_STATUS"
assert_contains "the failure keeps the existing message" \
    "the service failed to start" "$T_OUT"
assert_file_absent "a genuinely failed openrc start rolls back the config" "$S5_CFG"
assert_file_absent "and the init script" "$S5_INITSCRIPT"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/debian-12"
rm -f "$S5_TEST_ROOT/svc_start_transient_fail"

# --- The third CI run's Alpine 3.20 shape: the warning is a LOCK contention.
# openrc-run prints "already starting" and exits 1 when the service's exclusive
# lock cannot be flocked (svc_lock/EWOULDBLOCK), and at the re-query the state
# is genuinely stopped -- some other process held the lock without marking
# starting. The transient classifier (status re-query) correctly says inactive;
# only a bounded retry of the start command itself survives. A one-attempt
# start, however well classified, fails this install. Modelled by
# svc_start_locked: first start refuses, second behaves normally.
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active" \
    "$S5_TEST_ROOT/svc_latebind_seen"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/alpine-3.20"
printf '2\n' >"$S5_TEST_ROOT/svc_latebind"
: >"$S5_TEST_ROOT/svc_start_locked"
s5env_install_answers y 31094 alplockuser 'TestPassword_123~x'
printf '%s:%s' alplockuser 'TestPassword_123~x' >"$S5_TEST_ROOT/expected_creds"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_eq "openrc install survives a transient start-lock contention" 0 "$T_STATUS"
assert_contains "the lock warning really fired" "already starting" "$T_OUT"
assert_file_exists "lock-contention install keeps the init script" "$S5_INITSCRIPT"
assert_file_exists "lock-contention install keeps the state" "$S5_STATE"
S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/debian-12"
rm -f "$S5_TEST_ROOT/svc_latebind" "$S5_TEST_ROOT/svc_latebind_seen" \
    "$S5_TEST_ROOT/svc_start_locked"

# ==========================================================================
# F28 (HIGH)  The static check must run BEFORE anything is started.
#
# s5_static_check_cfg is the only thing standing between a rendered config and a
# running proxy: it is what rejects `auth none`, `auth iponly`, BIND/UDPASSOC,
# the 20 forbidden directives, a missing destination-deny CIDR, and denies
# ordered after the allow. Its entire value is positional -- and that position
# was asserted nowhere. test_static_check.sh proves the checker WORKS; the
# systemctl stub's `cfgpresent=yes` proves the config FILE EXISTED at start
# time; neither proves the check had RUN. Moving the call below s5_service_active
# keeps the full suite green while a config carrying `auth none` is written, the
# unit enabled, and the proxy started and briefly serving traffic before the
# rejection is printed and the install rolls back.
#
# Asserted behaviourally, not by line number: a line-order comparison passes for
# any call site after the render, including one below the start. This block runs
# LAST in the file because it replaces a production function for good.
# ==========================================================================
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"

s5_static_check_cfg() {
    s5_err "SIMULATED STATIC CHECK REJECTION"
    return 1
}

s5env_install_answers y 31083 fourthuser 'TestPassword_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "install fails when the static check rejects the config" 0 "$T_STATUS"
assert_contains "the rejection reaches the operator" "SIMULATED STATIC CHECK REJECTION" "$T_OUT"
t_assert_never_called "the service is never started over a rejected config" 'systemctl start'
t_assert_never_called "and the unit is never enabled either" 'systemctl enable'
assert_file_absent "the rejected config is not left behind" "$S5_CFG"
assert_file_absent "no credentials are left behind" "$S5_USERSCFG"
assert_file_absent "no binary is left behind" "$S5_BIN"

# ==========================================================================
# A failure while creating the initial state used to leave an empty state
# directory behind. Rollback is now armed before state_begin, while state_begin
# itself compensates any partial directory/file claim.
# ==========================================================================
s5env_reset_transcript
rm -rf "$S5_SYSCONFDIR" "$S5_STATEDIR" "$S5_PREFIX"
rm -f "$S5_UNIT" "$S5_INITSCRIPT" "$S5_TEST_ROOT/svc_active"
: >"$S5_TEST_ROOT/stub_passwd"
: >"$S5_TEST_ROOT/stub_group"
mktemp() {
    case "$1" in
    *.s5state.* | "$S5_STATEDIR"/.s5new.*) return 1 ;;
    *) command mktemp "$@" ;;
    esac
}
s5env_install_answers y 31086 stateuser 'TestPassword_123~x'
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
unset -f mktemp
assert_ne "install fails when the state file cannot be created" 0 "$T_STATUS"
assert_file_absent "no state directory is left behind" "$S5_STATEDIR"
t_assert_never_called "no account was created before the state existed" 'useradd'
t_assert_never_called "and nothing was built" 'make -f'

t_summary
