#!/bin/sh
# Alpine/OpenRC adapter regression tests.

S5T_NAME=test_xray_openrc
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
ROOT=${S5_REPO_ROOT}
t_mktestroot
mkdir -p "$S5_TEST_ROOT/bin" "$S5_TEST_ROOT/etc/init.d"
t_source_production "$ROOT/tests/fixtures/os-release/alpine-3.20"
S5_ARCHNAME=amd64
S5_LANG=en
S5_PORT=23456
S5_LISTEN=127.0.0.1
S5_INIT=openrc
S5_OS_FAMILY=alpine

# Platform detection must select the OpenRC adapter and reject old Alpine.
s5_detect_platform
assert_eq "Alpine selects OpenRC" 0 "$?"
assert_eq "Alpine init" openrc "$S5_INIT"
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/alpine-3.19"
t_run s5_detect_platform
assert_ne "Alpine below 3.20 rejected" 0 "$T_STATUS"
S5_OSRELEASE="$ROOT/tests/fixtures/os-release/alpine-3.20"
s5_detect_platform

# Only alpine/openrc, debian/systemd and el/systemd are supported pairings.
# Chaining && and
# || in a single guard is left-associative, which silently rejected alpine/openrc
# and made every Alpine update fail with no diagnostic.
_obfamily=$S5_OS_FAMILY
_obinit=$S5_INIT
for _obcase in alpine:openrc:ok debian:systemd:ok el:systemd:ok \
    alpine:systemd:no debian:openrc:no el:openrc:no unknown:systemd:no :systemd:no; do
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

# Raw target delivery needs no archive extractor. Other missing runtime tools
# are still discovered in the same package query.
assert_not_contains "Alpine install does not request Info-ZIP" unzip "$(s5_runtime_packages install)"
assert_not_contains "Alpine update does not request Info-ZIP" unzip "$(s5_runtime_packages update)"

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
assert_contains "OpenRC permits two rapid crash recoveries" 'respawn_max=2' "$_openrc"
assert_contains "OpenRC bounds the recovery window" 'respawn_period=60' "$_openrc"
assert_contains "OpenRC delays each recovery" 'respawn_delay=1' "$_openrc"
assert_contains "OpenRC owns pidfile" 'pidfile="' "$_openrc"

# Standalone writers must select their own destination, even after a different
# backend was used in the same shell. The old alias retained the OpenRC path.
S5_INIT=systemd
s5_write_unit
assert_file_exists "standalone systemd write uses the systemd path" \
    "$S5_UNITDIR/$S5_PROJECT.service"
assert_contains "switching backend preserves the existing OpenRC artifact" \
    '#!/sbin/openrc-run' "$(cat "$S5_INITSCRIPT")"
S5_INIT=openrc
s5_write_unit
assert_contains "switching back writes an OpenRC script" \
    '#!/sbin/openrc-run' "$(cat "$S5_INITSCRIPT")"

# A transient nonzero rc-service result is accepted only when the manager says
# the service is actually starting; a failed/inactive service remains an error.
t_stub rc-service <<'RC'
#!/bin/sh
if [ "$2" = status ]; then
    if [ -f "$S5_TEST_ROOT/active" ]; then exit 8; fi
    exit 3
fi
if [ -f "$S5_TEST_ROOT/fail-start" ]; then exit 7; fi
: >"$S5_TEST_ROOT/active"
exit 7
RC
PATH="$S5_TEST_ROOT/bin:$PATH"
export PATH
s5_svc start
assert_eq "OpenRC starting state reclassifies start" 0 "$?"
rm -f "$S5_TEST_ROOT/active"
: >"$S5_TEST_ROOT/fail-start"
s5_svc start
assert_ne "OpenRC inactive start remains failure" 0 "$?"

# s5_service_state must fail closed like the systemd arm, where only exit 3
# proves the service is down. 16 is OpenRC's `inactive`, which supervise-daemon
# leaves behind while the supervised process is still alive and still holding the
# port, and 1 is a plain rc-service error; treating either as stopped let
# uninstall delete the config, binary and account from under a live proxy.
t_stub rc-service <<'RC'
#!/bin/sh
if [ "$2" = status ]; then exit "$(cat "$S5_TEST_ROOT/statuscode")"; fi
exit "$(cat "$S5_TEST_ROOT/actioncode")"
RC
printf '0\n' >"$S5_TEST_ROOT/actioncode"
for _sacase in 0:0 8:0 3:1 16:2 1:2 32:3 4:2; do
    printf '%s\n' "${_sacase%%:*}" >"$S5_TEST_ROOT/statuscode"
    s5_service_state
    assert_eq "rc-service status ${_sacase%%:*} means ${_sacase#*:}" \
        "${_sacase#*:}" "$?"
done

# `status` is the public boundary: an OpenRC crash must be named rather than
# collapsed into the same diagnosis as an rc-service error. The listener is a
# separate observation and remains visible even when the manager reports a crash.
s5t_openrc_crashed_status() (
    S5_LANG=$1
    S5_PORT=23456
    S5_USERNAME=alice
    S5_INSTALLED_RELEASE=v26.3.27
    printf '32\n' >"$S5_TEST_ROOT/statuscode"
    : >"$S5_TEST_ROOT/status-lock"
    s5_open_locked() { return 0; }
    s5_listener_state() { return 1; }
    s5_lock_release() { rm -f "$S5_TEST_ROOT/status-lock"; }
    s5_cmd_status
)
for _sc_lang in en zh; do
    t_run s5t_openrc_crashed_status "$_sc_lang"
    assert_ne "status fails when OpenRC reports a crash in $_sc_lang" 0 "$T_STATUS"
    case "$_sc_lang" in
    en)
        assert_contains "English status names the OpenRC crash" \
            'service: crashed;' "$T_OUT"
        assert_contains "English crash still reports the listener observation" \
            'Xray is not listening on port 23456.' "$T_OUT"
        ;;
    zh)
        assert_contains "Chinese status names the OpenRC crash" \
            '服务：已崩溃；' "$T_OUT"
        assert_contains "Chinese crash still reports the listener observation" \
            'Xray 未在端口 23456 上监听。' "$T_OUT"
        ;;
    esac
    assert_file_absent "crashed status releases the operation lock in $_sc_lang" \
        "$S5_TEST_ROOT/status-lock"
done

# A crashed child whose port is still held: the two observations stay
# independent, so status names the crash and the listener it still sees.
s5t_openrc_crashed_listening() (
    S5_LANG=en
    S5_PORT=23456
    S5_USERNAME=alice
    S5_INSTALLED_RELEASE=v26.3.27
    printf '32\n' >"$S5_TEST_ROOT/statuscode"
    s5_open_locked() { return 0; }
    s5_listener_state() { return 0; }
    s5_lock_release() { return 0; }
    s5_cmd_status
)
t_run s5t_openrc_crashed_listening
assert_ne "a crashed child with a live listener still fails status" 0 "$T_STATUS"
assert_contains "status names the crash beside a live listener" 'service: crashed;' "$T_OUT"
assert_contains "status still reports the live listener" 'Xray is listening on port 23456.' "$T_OUT"

# Command-level uninstall must refuse while OpenRC reports the child crashed:
# the supervisor still manages the service, so nothing proves it stopped.
s5t_openrc_crashed_uninstall() (
    S5_LANG=en
    sleep() { :; }
    printf '32\n' >"$S5_TEST_ROOT/statuscode"
    S5_UNINSTALL_PHASE=prepared
    s5_uninstall_checkpoint() { printf '%s\n' "$1" >>"$S5_TEST_ROOT/uninstall-phases"; }
    s5_cleanup_own_temps() { return 0; }
    s5_cleanup_transaction() { return 0; }
    s5_uninstall_run
)
: >"$S5_TEST_ROOT/uninstall-phases"
t_run s5t_openrc_crashed_uninstall
assert_ne "uninstall refuses a crashed OpenRC service" 0 "$T_STATUS"
assert_contains "the refusal says the service did not stop" 'could not verify that the Xray service stopped' "$T_OUT"
assert_eq "a crashed service never reaches the stopped phase" '' "$(cat "$S5_TEST_ROOT/uninstall-phases")"

# s5_wait_stopped may only report success on a state that proves the process is
# gone. sleep is stubbed because the real wait is fifteen one-second polls.
sleep() { :; }
printf '3\n' >"$S5_TEST_ROOT/statuscode"
t_run s5_wait_stopped
assert_eq "a stopped service satisfies the stop wait" 0 "$T_STATUS"
printf '16\n' >"$S5_TEST_ROOT/statuscode"
t_run s5_wait_stopped
assert_ne "an inactive service does not satisfy the stop wait" 0 "$T_STATUS"
printf '32\n' >"$S5_TEST_ROOT/statuscode"
t_run s5_wait_stopped
assert_ne "a crashed child does not prove its supervisor stopped" 0 "$T_STATUS"
unset -f sleep

# The "nonzero but already active" fallback is sound for start and wrong for
# restart: an old instance that survived a failed stop also looks active, so a
# restart whose stop phase failed used to report success.
printf '0\n' >"$S5_TEST_ROOT/statuscode"
printf '7\n' >"$S5_TEST_ROOT/actioncode"
t_run s5_svc restart
assert_ne "a failed restart is a failure even while active" 0 "$T_STATUS"
t_run s5_svc start
assert_eq "a start against an active service still succeeds" 0 "$T_STATUS"
printf '0\n' >"$S5_TEST_ROOT/actioncode"

# supervise-daemon records the supervised process itself in child_pid, and the
# pidfile holds the supervisor. Alpine CI evidence: child_pid=378, pidfile=377,
# ps shows 377 supervising 378, and the kernel attributes the listener to 378.
# Walking to /proc children from child_pid lands on Xray's two logger children,
# which made a healthy service look like it was not listening.
mkdir -p "$S5_OPENRC_OPTION_DIR"
printf '378\n' >"$S5_OPENRC_OPTION_DIR/child_pid"
t_stub ss <<'SS'
#!/bin/sh
printf '%s\n' 'LISTEN 0 4096 127.0.0.1:23456 0.0.0.0:* users:(("xray",pid=378,fd=3))'
SS
s5_listener_state
assert_eq "OpenRC listener accepts the supervised child" 0 "$?"

# The supervisor never owns the listener, so a supervisor-owned endpoint is not
# proof that Xray itself is listening.
t_stub ss <<'SS'
#!/bin/sh
printf '%s\n' 'LISTEN 0 4096 127.0.0.1:23456 0.0.0.0:* users:(("supervise-daemon",pid=377,fd=3))'
SS
t_run s5_listener_state
assert_ne "OpenRC listener refuses a supervisor-owned endpoint" 0 "$T_STATUS"

# An absent child_pid means the service is not running, not an unobservable state.
rm -f "$S5_OPENRC_OPTION_DIR/child_pid"
t_run s5_listener_state
assert_eq "OpenRC missing child_pid reports absent" 1 "$T_STATUS"
# A child_pid that exists but yields no pid proves nothing about the listener:
# unreadable (a directory makes cat fail even for root), empty, or not a pid.
mkdir "$S5_OPENRC_OPTION_DIR/child_pid"
t_run s5_listener_state
assert_eq "OpenRC unreadable child_pid is unobservable" 2 "$T_STATUS"
rmdir "$S5_OPENRC_OPTION_DIR/child_pid"
for _child_pid in '' abc 0; do
    printf '%s\n' "$_child_pid" >"$S5_OPENRC_OPTION_DIR/child_pid"
    t_run s5_listener_state
    assert_eq "OpenRC child_pid [$_child_pid] is unobservable" 2 "$T_STATUS"
done
rm -f "$S5_OPENRC_OPTION_DIR/child_pid"

# A failed init-script write must not report success. The OpenRC arm ended in
# `return $?` after an assignment, and an assignment always succeeds, so the
# caller recorded S5_CREATED_UNIT for a file that was never created and then ran
# sha256sum on a missing path. The failing writer is scoped to a subshell, so
# the cases after this one keep the real s5_atomic_write.
s5t_failing_unit_write() (
    S5_INIT=$1
    s5_atomic_write() { return 1; }
    s5_write_unit
)
t_run s5t_failing_unit_write openrc
assert_ne "a failed OpenRC artifact write is a failure" 0 "$T_STATUS"
t_run s5t_failing_unit_write systemd
assert_ne "a failed systemd unit write is a failure" 0 "$T_STATUS"

# Each service verb dispatches to exactly one backend command. Record what
# rc-service and rc-update receive so a verb cannot be mapped to the wrong action
# or dropped. rc-service actions succeed here; enable/disable go through rc-update.
t_stub rc-service <<'RC'
#!/bin/sh
if [ "$2" = status ]; then exit 3; fi
printf 'rc-service %s %s\n' "$1" "$2" >>"$S5_TEST_ROOT/svc-transcript"
exit 0
RC
t_stub rc-update <<'RC'
#!/bin/sh
printf 'rc-update %s %s %s\n' "$1" "$2" "$3" >>"$S5_TEST_ROOT/svc-transcript"
exit 0
RC
: >"$S5_TEST_ROOT/svc-transcript"
s5_svc stop
assert_eq "OpenRC stop calls rc-service stop" 1 \
    "$(grep -c "^rc-service $S5_PROJECT stop\$" "$S5_TEST_ROOT/svc-transcript")"
s5_svc restart
assert_eq "OpenRC restart calls rc-service restart" 1 \
    "$(grep -c "^rc-service $S5_PROJECT restart\$" "$S5_TEST_ROOT/svc-transcript")"
s5_svc enable
assert_eq "OpenRC enable adds the service to the default runlevel" 1 \
    "$(grep -c "^rc-update add $S5_PROJECT default\$" "$S5_TEST_ROOT/svc-transcript")"
s5_svc disable
assert_eq "OpenRC disable removes the service from the default runlevel" 1 \
    "$(grep -c "^rc-update del $S5_PROJECT default\$" "$S5_TEST_ROOT/svc-transcript")"

_reload_before=$(cat "$S5_TEST_ROOT/svc-transcript")
t_run s5_svc reload
assert_eq "OpenRC reload succeeds without an external command" 0 "$T_STATUS"
assert_eq "OpenRC reload leaves the transcript unchanged" "$_reload_before" "$(cat "$S5_TEST_ROOT/svc-transcript")"
t_run s5_svc unknown
assert_eq "OpenRC rejects unknown lifecycle verbs" 1 "$T_STATUS"

. "$ROOT/tests/lib/xray-fixture.sh"
t_xray_fixture 23456
s5_svc reload
assert_eq "systemd reload succeeds" 0 "$?"
assert_eq "systemd reload invokes exactly one daemon-reload" 'systemctl daemon-reload' "$(cat "$S5_TEST_ROOT/transcript")"
t_run s5_svc unknown
assert_eq "systemd rejects unknown lifecycle verbs" 1 "$T_STATUS"

S5_PORT=23455
S5_LISTENER_PROBE=$S5_TEST_ROOT/listenerprobe
cat >"$S5_LISTENER_PROBE" <<'PROBE'
#!/bin/sh
printf '%s\n' "$2" >"$S5_TEST_ROOT/listener-port"
exit 0
PROBE
chmod 0755 "$S5_LISTENER_PROBE"
s5_wait_listening 23456
assert_eq "listener wait observes its requested port" 0 "$?"
assert_eq "listener wait passes its port to the probe" 23456 "$(cat "$S5_TEST_ROOT/listener-port")"
assert_eq "listener wait leaves the configured port unchanged" 23455 "$S5_PORT"

t_summary
