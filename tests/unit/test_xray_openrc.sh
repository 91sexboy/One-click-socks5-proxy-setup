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
# shellcheck disable=SC1091
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

# Only alpine/openrc and non-alpine/systemd are supported pairings. Chaining && and
# || in a single guard is left-associative, which silently rejected alpine/openrc
# and made every Alpine update fail with no diagnostic.
_obfamily=$S5_OS_FAMILY
_obinit=$S5_INIT
for _obcase in alpine:openrc:ok debian:systemd:ok el:systemd:ok \
    alpine:systemd:no debian:openrc:no el:openrc:no; do
    S5_OS_FAMILY=${_obcase%%:*}
    _obrest=${_obcase#*:}
    S5_INIT=${_obrest%:*}
    t_run s5_backend_supported
    if [ "${_obrest##*:}" = ok ]; then
        assert_eq "$S5_OS_FAMILY/$S5_INIT is a supported backend" 0 "$T_STATUS"
    else
        assert_ne "$S5_OS_FAMILY/$S5_INIT is refused" 0 "$T_STATUS"
    fi
done
S5_OS_FAMILY=$_obfamily
S5_INIT=$_obinit

# BusyBox ships a stripped unzip that has no -Z, so `command -v unzip` succeeds on a
# bare Alpine host while the archive inspection in s5_download_engine cannot work.
# Info-ZIP must therefore be requested unconditionally.
assert_contains "Alpine install requests Info-ZIP unzip" unzip "$(s5_runtime_packages install)"
assert_contains "Alpine update requests Info-ZIP unzip" unzip "$(s5_runtime_packages update)"

# Only install and update may install packages; read-only and destructive modes
# must never mutate the host's package set.
assert_eq "Alpine status installs no packages" '' "$(s5_runtime_packages status)"
assert_eq "Alpine restart installs no packages" '' "$(s5_runtime_packages restart)"
assert_eq "Alpine uninstall installs no packages" '' "$(s5_runtime_packages uninstall)"
assert_eq "Alpine show installs no packages" '' "$(s5_runtime_packages show)"

# systemd targets never use apk at all.
S5_INIT=systemd
assert_eq "systemd install requests no apk packages" '' "$(s5_runtime_packages install)"
S5_INIT=openrc

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

# s5_service_active must fail closed like the systemd arm, where only exit 3
# proves the service is down. 16 is OpenRC's `inactive`, which supervise-daemon
# leaves behind while the supervised process is still alive and still holding the
# port, and 1 is a plain rc-service error; treating either as stopped let
# uninstall delete the config, binary and account from under a live proxy.
cat >"$S5_TEST_ROOT/bin/rc-service" <<'RC'
#!/bin/sh
if [ "$2" = status ]; then exit "$(cat "$S5_TEST_ROOT/statuscode")"; fi
exit "$(cat "$S5_TEST_ROOT/actioncode")"
RC
chmod 755 "$S5_TEST_ROOT/bin/rc-service"
printf '0\n' >"$S5_TEST_ROOT/actioncode"
for _sacase in 0:0 8:0 3:1 16:2 1:2 32:2 4:2; do
    printf '%s\n' "${_sacase%%:*}" >"$S5_TEST_ROOT/statuscode"
    s5_service_active
    assert_eq "rc-service status ${_sacase%%:*} means ${_sacase#*:}" \
        "${_sacase#*:}" "$?"
done

# s5_wait_stopped may only report success on a state that proves the process is
# gone. sleep is stubbed because the real wait is fifteen one-second polls.
sleep() { :; }
printf '3\n' >"$S5_TEST_ROOT/statuscode"
t_run s5_wait_stopped
assert_eq "a stopped service satisfies the stop wait" 0 "$T_STATUS"
printf '16\n' >"$S5_TEST_ROOT/statuscode"
t_run s5_wait_stopped
assert_ne "an inactive service does not satisfy the stop wait" 0 "$T_STATUS"
unset -f sleep

# The "nonzero but already active" fallback is sound for start and wrong for
# restart: an old instance that survived a failed stop also looks active, so a
# restart whose stop phase failed used to report success.
printf '0\n' >"$S5_TEST_ROOT/statuscode"
printf '7\n' >"$S5_TEST_ROOT/actioncode"
t_run s5_service_restart
assert_ne "a failed restart is a failure even while active" 0 "$T_STATUS"
t_run s5_service_start
assert_eq "a start against an active service still succeeds" 0 "$T_STATUS"
printf '0\n' >"$S5_TEST_ROOT/actioncode"

# supervise-daemon records the supervised process itself in child_pid, and the
# pidfile holds the supervisor. Alpine CI evidence: child_pid=378, pidfile=377,
# ps shows 377 supervising 378, and the kernel attributes the listener to 378.
# Walking to /proc children from child_pid lands on Xray's two logger children,
# which made a healthy service look like it was not listening.
mkdir -p "$S5_OPENRC_OPTION_DIR"
printf '378\n' >"$S5_OPENRC_OPTION_DIR/child_pid"
cat >"$S5_TEST_ROOT/bin/ss" <<'SS'
#!/bin/sh
printf '%s\n' 'LISTEN 0 4096 127.0.0.1:23456 0.0.0.0:* users:(("xray",pid=378,fd=3))'
SS
chmod 755 "$S5_TEST_ROOT/bin/ss"
s5_listener_state
assert_eq "OpenRC listener accepts the supervised child" 0 "$?"
# shellcheck disable=SC2154
assert_eq "OpenRC listener owner is child_pid" 378 "$_slpid"

# The supervisor never owns the listener, so a supervisor-owned endpoint is not
# proof that Xray itself is listening.
cat >"$S5_TEST_ROOT/bin/ss" <<'SS'
#!/bin/sh
printf '%s\n' 'LISTEN 0 4096 127.0.0.1:23456 0.0.0.0:* users:(("supervise-daemon",pid=377,fd=3))'
SS
chmod 755 "$S5_TEST_ROOT/bin/ss"
t_run s5_listener_state
assert_ne "OpenRC listener refuses a supervisor-owned endpoint" 0 "$T_STATUS"

# An absent child_pid means the service is not running, not an unobservable state.
rm -f "$S5_OPENRC_OPTION_DIR/child_pid"
t_run s5_listener_state
assert_eq "OpenRC missing child_pid reports absent" 1 "$T_STATUS"

# A failed init-script write must not report success. The OpenRC arm ended in
# `return $?` after an assignment, and an assignment always succeeds, so the
# caller recorded S5_CREATED_UNIT for a file that was never created and then ran
# sha256sum on a missing path. This case comes last: it leaves s5_atomic_write
# stubbed for the remainder of the file.
s5_atomic_write() { return 1; }
t_run s5_write_unit
assert_ne "a failed OpenRC artifact write is a failure" 0 "$T_STATUS"
S5_INIT=systemd
t_run s5_write_unit
assert_ne "a failed systemd unit write is a failure" 0 "$T_STATUS"
S5_INIT=openrc

t_summary
