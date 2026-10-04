#!/bin/sh
# Hold one memory stage's tunnels and prove they are live around its sample.
# Sourced after lifecycle-common.sh by memory-report.sh and by its self-test
# (tests/protocol/memory_holder_selftest.py); run from the repository root.
#
# Every function takes the work directory first. It holds pass (the proxy
# credentials), report (the duplex target's metrics) and the holder's own files:
# held (its readiness), held.check (its latest echo round) and held.log.
# memory_hold_start sets holder_pid. A refusal stops and reaps the holder before
# it returns, so no caller path leaves the holder or its sockets behind, and the
# holder deletes held and held.check on every exit, so neither file outlives it.
#
# A stage's label is evidence only when the holder echoed a fresh frame on every
# tunnel and the target counts the same tunnels in that stage's hello cohort --
# at readiness, and again before and after the sample.

# The holder's per-round echo deadline, in whole seconds. The self-test shortens
# it; the coordinator's own waits are derived from it, so both stay bounded.
memory_hold_round_seconds=${MEMORY_HOLD_ROUND_SECONDS:-10}

# memory_holder_gone <pid>: the process has exited; an unreaped zombie counts.
memory_holder_gone() {
    kill -0 "$1" 2>/dev/null || return 0
    _mhg_state=$(sed 's/.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f1)
    [ "$_mhg_state" = Z ]
}

# memory_target_tunnels <report> [cohort]: the target's live tunnels in one hello
# cohort or, without one, every tunnel it accepted and has not yet closed.
memory_target_tunnels() {
    python3 - "$1" "${2:-}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="ascii") as handle:
    report = json.load(handle)
if sys.argv[2]:
    print(report["cohorts"].get(sys.argv[2], {}).get("active", 0))
else:
    print(report["accepted"] - sum(report["closes"].values()))
PY
}

# memory_hold_abort: stop and reap the holder, reporting how it ended.
memory_hold_abort() {
    [ -n "${holder_pid:-}" ] || return 0
    _mha_pid=$holder_pid
    holder_pid=''
    kill -TERM "$_mha_pid" 2>/dev/null || true
    lifecycle_wait_until 50 0.1 memory_holder_gone "$_mha_pid" ||
        kill -KILL "$_mha_pid" 2>/dev/null || true
    _mha_status=0
    wait "$_mha_pid" 2>/dev/null || _mha_status=$?
    printf 'memory holder: the holder ended with status %s\n' "$_mha_status" >&2
}

# memory_hold_refuse <dir> <reason>: name the refusal with the target's close
# reasons, then stop the holder and drop the answers a killed holder could not.
# Always returns 1.
memory_hold_refuse() {
    printf 'memory holder: %s\n' "$2" >&2
    python3 -c 'import json, sys; print("memory holder: target close reasons %s" % json.load(open(sys.argv[1]))["closes"])' \
        "$1/report" >&2 || true
    memory_hold_abort
    rm -f "$1/held" "$1/held.check"
    return 1
}

memory_hold_answered() { test -s "$1" || memory_holder_gone "$holder_pid"; }

# memory_hold_confirm <dir> <stage> <when> <answer-file>: the holder, still
# running, answered for every tunnel and the target counts the same cohort.
memory_hold_confirm() {
    _mhc_live=$(cat "$4" 2>/dev/null) || _mhc_live=''
    if memory_holder_gone "$holder_pid"; then
        memory_hold_refuse "$1" "conn$2 $3: the holder exited before answering"
        return 1
    fi
    if [ "$_mhc_live" != "$2" ]; then
        memory_hold_refuse "$1" "conn$2 $3: the holder echoed ${_mhc_live:-no} tunnels, not $2"
        return 1
    fi
    if _mhc_active=$(memory_target_tunnels "$1/report" "cohort-held-$2"); then :; else
        memory_hold_refuse "$1" "conn$2 $3: the target report is unreadable"
        return 1
    fi
    if [ "$_mhc_active" != "$2" ]; then
        memory_hold_refuse "$1" "conn$2 $3: the target counts $_mhc_active live tunnels, not $2"
        return 1
    fi
    printf 'conn%s_%s_echoed_tunnels=%s\n' "$2" "$3" "$_mhc_live"
    printf 'conn%s_%s_target_active=%s\n' "$2" "$3" "$_mhc_active"
}

# memory_hold_start <dir> <stage> <proxy-port> <target-host> <target-port>:
# open <stage> tunnels and wait for every one to have echoed a frame.
memory_hold_start() {
    rm -f "$1/held" "$1/held.check"
    python3 tests/protocol/hold_connections.py --host 127.0.0.1 --port "$3" \
        --target-host "$4" --target-port "$5" --passfile "$1/pass" \
        --count "$2" --cohort "cohort-held-$2" \
        --ready-file "$1/held" --check-file "$1/held.check" \
        --round-seconds "$memory_hold_round_seconds" --max-seconds 60 \
        3>&- >"$1/held.log" 2>&1 &
    holder_pid=$!
    # Opening is sequential: the holder's budget is its round plus 0.25 s a tunnel.
    lifecycle_wait_until $(((memory_hold_round_seconds + 5) * 10 + $2 * 3)) 0.1 \
        memory_hold_answered "$1/held" || true
    memory_hold_confirm "$1" "$2" ready "$1/held"
}

# memory_hold_verify <dir> <stage> <when>: one more echo round on every tunnel.
memory_hold_verify() {
    if memory_holder_gone "$holder_pid"; then
        memory_hold_refuse "$1" "conn$2 $3: the holder exited before its check"
        return 1
    fi
    rm -f "$1/held.check"
    kill -USR1 "$holder_pid"
    lifecycle_wait_until $(((memory_hold_round_seconds + 5) * 10)) 0.1 \
        memory_hold_answered "$1/held.check" || true
    memory_hold_confirm "$1" "$2" "$3" "$1/held.check"
}

# memory_hold_stop <dir> <stage>: the stop request is the only expected exit,
# and the holder must report a healthy hold by exiting 0.
memory_hold_stop() {
    if memory_holder_gone "$holder_pid"; then
        memory_hold_refuse "$1" "conn$2: the holder exited before its stop request"
        return 1
    fi
    _mhp_pid=$holder_pid
    kill -TERM "$_mhp_pid"
    if ! lifecycle_wait_until $(((memory_hold_round_seconds + 5) * 10)) 0.1 \
        memory_holder_gone "$_mhp_pid"; then
        memory_hold_refuse "$1" "conn$2: the holder did not stop"
        return 1
    fi
    holder_pid=''
    _mhp_status=0
    wait "$_mhp_pid" 2>/dev/null || _mhp_status=$?
    if [ "$_mhp_status" -ne 0 ]; then
        printf 'memory holder: conn%s: the holder failed its hold with status %s\n' "$2" "$_mhp_status" >&2
        rm -f "$1/held" "$1/held.check"
        return 1
    fi
}

# memory_hold_idle <dir> <when>: the idle stage holds no tunnel at the target.
memory_hold_idle() {
    lifecycle_wait_until 50 0.1 test -s "$1/report" || true
    if _mhi_open=$(memory_target_tunnels "$1/report"); then :; else
        printf 'memory holder: idle %s: the target report is unreadable\n' "$2" >&2
        return 1
    fi
    if [ "$_mhi_open" != 0 ]; then
        printf 'memory holder: idle %s: the target holds %s tunnels\n' "$2" "$_mhi_open" >&2
        return 1
    fi
    printf 'idle_%s_target_open=0\n' "$2"
}
