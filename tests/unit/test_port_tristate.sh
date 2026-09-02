#!/bin/sh
# tests/unit/test_port_tristate.sh - regression: "cannot observe" is never
# "in use", at every caller of the listen-state probe.
#
# s5_port_free answers three ways: 0 free, 1 a LISTEN socket owns the port,
# 2 the listen state could not be observed at all. Four of its five callers
# dispatch on all three. s5_reconfigure_apply folded them with `-ne 0`, so a
# probe that broke between the precheck and the post-stop re-check -- iproute2
# removed mid-run, a restricted netns, `ss` failing inside a container -- made
# the update print "port N is still unavailable after stopping the old proxy"
# one line after the probe itself had said it could not determine that, then
# roll back a healthy install over a collision nobody had ever observed.
#
# This file lives apart from test_reconfigure.sh because it substitutes
# s5_port_free's answer, and nothing else here needs the real one. Staging, the
# stop proof, the transaction, the restore and the verification all run for real.

S5T_NAME=test_port_tristate
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

BASE_PORT=41090
BASE_USER=tristateuser
BASE_PASS='TriStatePass_1234'

s5env_full_install "$BASE_PORT" "$BASE_USER" "$BASE_PASS"
assert_eq "the baseline install is complete" 0 "$?"
assert_eq "the baseline listener is up" "$BASE_PORT" "$(cat "$S5_TEST_ROOT/svc_active")"
_before_users=$(cat "$S5_USERSCFG")
_before_cfg=$(cat "$S5_CFG")

# ==========================================================================
# The unobservable answer must be reported as unobservable, and must not be
# dressed up as a port collision.
# ==========================================================================
# The substitution keys on the call shape, not on a call counter. Readiness,
# status and the precheck all ask about a specific address; only the post-stop
# collision re-check asks about the bare port. So an address-bearing probe keeps
# answering from the harness stub and the install stays observably healthy,
# while the one call under test reports the third state.
s5env_reset_transcript
s5_port_free() {
    if [ -z "${2:-}" ]; then return 2; fi
    "$S5_PORT_PROBE" "$1" "$2"
}
s5env_install_answers y "$BASE_PORT" "$BASE_USER" "$BASE_PASS"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "an unobservable port refuses the update" 0 "$T_STATUS"
assert_not_contains "an unobservable probe is not reported as a collision" \
    "$(s5_msg reconfigure.port_not_free "$BASE_PORT")" "$T_OUT"
assert_contains "an unobservable probe names the listen-state failure" \
    "$(s5_msg reconfigure.port_unverified "$BASE_PORT")" "$T_OUT"

# The refusal is a refusal, not a half-applied update: the previous credential
# and configuration survive byte for byte and the transaction is gone.
assert_eq "a refused update keeps the old credential" "$_before_users" "$(cat "$S5_USERSCFG")"
assert_eq "a refused update keeps the old configuration" "$_before_cfg" "$(cat "$S5_CFG")"
assert_file_absent "a refused update leaves no transaction" "$S5_TXNDIR"
assert_file_absent "a refused update releases its lock" "$S5_LOCKDIR"
assert_not_contains "a refused update reveals no password" "$BASE_PASS" "$T_OUT"

# ==========================================================================
# The same substitution must still refuse when the probe reports a real
# collision, and must say so in the collision's own words -- otherwise the
# assertion above would pass for a build that simply never reports anything.
# ==========================================================================
s5env_reset_transcript
s5_port_free() {
    if [ -z "${2:-}" ]; then return 1; fi
    "$S5_PORT_PROBE" "$1" "$2"
}
s5env_install_answers y "$BASE_PORT" "$BASE_USER" "$BASE_PASS"
t_run s5_cmd_install <"$S5_TEST_ROOT/answers"
assert_ne "an occupied port refuses the update" 0 "$T_STATUS"
assert_contains "an occupied port is reported as a collision" \
    "$(s5_msg reconfigure.port_not_free "$BASE_PORT")" "$T_OUT"
assert_not_contains "an occupied port is not reported as unobservable" \
    "$(s5_msg reconfigure.port_unverified "$BASE_PORT")" "$T_OUT"

S5_PASSWORD=''
S5_SECRET=''
t_summary
