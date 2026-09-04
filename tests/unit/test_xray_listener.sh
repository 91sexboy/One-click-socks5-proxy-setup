#!/bin/sh
# Xray listener ownership and ss normalization contract tests.

S5T_NAME=test_xray_listener
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

ROOT=${S5_REPO_ROOT}
t_mktestroot
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
mkdir -p "$S5_TEST_ROOT/bin"
cat >"$S5_TEST_ROOT/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
case "$*" in
*'MainPID'*) cat "$S5_TEST_ROOT/mainpid"; exit 0 ;;
*) exit 0 ;;
esac
SYSTEMCTL
cat >"$S5_TEST_ROOT/bin/ss" <<'SS'
#!/bin/sh
cat "$S5_TEST_ROOT/ss-output"
SS
chmod 0755 "$S5_TEST_ROOT/bin/systemctl" "$S5_TEST_ROOT/bin/ss"
PATH="$S5_TEST_ROOT/bin:$PATH"
export PATH
# shellcheck source=/dev/null
. "$ROOT/socks5.sh"

S5_LANG=en
S5_LISTEN=0.0.0.0
S5_PORT=23456
printf '1234\n' >"$S5_TEST_ROOT/mainpid"

listener_row() {
    printf '%s\n' "LISTEN 0 4096 $1 0.0.0.0:* users:((\"xray\",pid=$2,fd=3))" >"$S5_TEST_ROOT/ss-output"
}

listener_row '0.0.0.0:23456' 1234
s5_listener_state
assert_eq "canonical wildcard address is owned" 0 "$?"

listener_row '*:23456' 1234
s5_listener_state
assert_eq "ss star wildcard address is owned" 0 "$?"

listener_row '127.0.0.1:23456' 1234
s5_listener_state
assert_eq "wrong address is not ready" 1 "$?"

listener_row '0.0.0.0:23456' 1235
s5_listener_state
assert_eq "foreign pid is unverified" 2 "$?"

printf '%s\n' 'LISTEN 0 4096 0.0.0.0:23456 0.0.0.0:*' >"$S5_TEST_ROOT/ss-output"
s5_listener_state
assert_eq "missing process metadata is unverified" 2 "$?"

listener_row '0.0.0.0:23456' 12345
s5_listener_state
assert_eq "pid prefix is not ownership" 2 "$?"

printf '%s\n%s\n' \
    'LISTEN 0 4096 0.0.0.0:23456 0.0.0.0:* users:(('"'"'xray'"'"',pid=1234,fd=3))' \
    'LISTEN 0 4096 0.0.0.0:23456 0.0.0.0:* users:(('"'"'xray'"'"',pid=1234,fd=4))' >"$S5_TEST_ROOT/ss-output"
s5_listener_state
assert_eq "duplicate endpoint is unverified" 2 "$?"

printf '%s\n' 'CLOSE-WAIT 0 4096 0.0.0.0:23456 0.0.0.0:* users:(('"'"'xray'"'"',pid=1234,fd=3))' >"$S5_TEST_ROOT/ss-output"
s5_listener_state
assert_eq "non-listening state is unverified" 2 "$?"

printf '%s\n' 'ss failed' >"$S5_TEST_ROOT/ss-output"
cat >"$S5_TEST_ROOT/bin/ss" <<'SSFAIL'
#!/bin/sh
exit 1
SSFAIL
chmod 0755 "$S5_TEST_ROOT/bin/ss"
s5_listener_state
assert_eq "ss failure is unverified" 2 "$?"

t_summary
