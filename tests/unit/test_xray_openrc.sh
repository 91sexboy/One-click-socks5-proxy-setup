#!/bin/sh
# Alpine/OpenRC adapter regression tests.

S5T_NAME=test_xray_openrc
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
mkdir -p "$S5_TEST_ROOT/bin" "$S5_TEST_ROOT/etc/init.d"
S5_LIB_ONLY=1
S5_ASSUME_ROOT=1
S5_SKIP_OWNERSHIP=1
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/alpine-3.20"
S5_ARCHNAME=amd64
export S5_LIB_ONLY S5_ASSUME_ROOT S5_SKIP_OWNERSHIP S5_OSRELEASE
. "$ROOT/socks5.sh"
S5_LANG=en
S5_PORT=23456
S5_LISTEN=127.0.0.1
S5_INIT=openrc
S5_OS_FAMILY=alpine
S5_UNIT=$S5_INITSCRIPT

# Platform detection must select the OpenRC adapter and reject old Alpine.
s5_detect_platform
assert_eq "Alpine selects OpenRC" 0 "$?"
assert_eq "Alpine package manager" apk "$S5_PKGMGR"
assert_eq "Alpine init" openrc "$S5_INIT"
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/alpine-3.19"
t_run s5_detect_platform
assert_ne "Alpine below 3.20 rejected" 0 "$T_STATUS"
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/alpine-3.20"
s5_detect_platform

# The artifact is an executable OpenRC script, not a systemd unit, and carries
# no credential-bearing command arguments.
s5_write_unit
assert_file_exists "OpenRC artifact exists" "$S5_INITSCRIPT"
assert_mode "OpenRC artifact executable" 755 "$S5_INITSCRIPT"
_openrc=$(cat "$S5_INITSCRIPT")
assert_contains "OpenRC shebang" '#!/sbin/openrc-run' "$_openrc"
assert_contains "OpenRC runs Xray foreground" 'command_args="run -c' "$_openrc"
assert_contains "OpenRC drops privileges" 'command_user="xray-socks5:xray-socks5"' "$_openrc"
assert_contains "OpenRC uses supervisor" 'supervisor="supervise-daemon"' "$_openrc"
assert_contains "OpenRC limits respawns" 'respawn_max=1' "$_openrc"
assert_contains "OpenRC owns pidfile" 'pidfile="' "$_openrc"

# A transient nonzero rc-service result is accepted only when the manager says
# the service is actually starting; a failed/inactive service remains an error.
cat >"$S5_TEST_ROOT/bin/rc-service" <<'RC'
#!/bin/sh
if [ "$2" = status ]; then
    if [ -f "$S5_TEST_ROOT/active" ]; then exit 8; fi
    exit 3
fi
if [ -f "$S5_TEST_ROOT/fail-start" ]; then exit 7; fi
: >"$S5_TEST_ROOT/active"
exit 7
RC
chmod 755 "$S5_TEST_ROOT/bin/rc-service"
PATH="$S5_TEST_ROOT/bin:$PATH"
export PATH
s5_service_start
assert_eq "OpenRC starting state reclassifies start" 0 "$?"
rm -f "$S5_TEST_ROOT/active"
: >"$S5_TEST_ROOT/fail-start"
s5_service_start
assert_ne "OpenRC inactive start remains failure" 0 "$?"

# OpenRC records the supervisor PID in its option state. Readiness must resolve
# that supervisor to its single Xray child before comparing the kernel listener
# owner; treating the supervisor as the listener owner falsely rejects a healthy
# service.
mkdir -p "$S5_OPENRC_OPTION_DIR"
printf '900\n' >"$S5_OPENRC_OPTION_DIR/child_pid"
export S5_OPENRC_OPTION_DIR
_REAL_CAT=$(command -v cat)
export REAL_CAT=$_REAL_CAT
"$_REAL_CAT" >"$S5_TEST_ROOT/bin/cat" <<'CAT'
#!/bin/sh
case "${1:-}" in
"$S5_OPENRC_OPTION_DIR/child_pid") printf '900\n' ;;
/proc/900/task/900/children) printf '901\n' ;;
*) exec "$REAL_CAT" "$@" ;;
esac
CAT
chmod 755 "$S5_TEST_ROOT/bin/cat"
cat >"$S5_TEST_ROOT/bin/ss" <<'SS'
#!/bin/sh
printf '%s\n' 'LISTEN 0 128 127.0.0.1:23456 0.0.0.0:* users:(("xray",pid=901,fd=3))'
SS
chmod 755 "$S5_TEST_ROOT/bin/ss"
export REAL_CAT=$_REAL_CAT
if [ "${S5_TEST_SHELL:-}" != 'busybox sh' ]; then
s5_listener_state
assert_eq "OpenRC listener resolves supervised Xray child" 0 "$?"
assert_eq "OpenRC listener uses child PID" 901 "$_slpid"
else
    t_skip "OpenRC listener child resolution" "BusyBox test shell cannot stub /proc safely"
fi

t_summary
