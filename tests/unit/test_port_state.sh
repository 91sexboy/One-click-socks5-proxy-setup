#!/bin/sh
# tests/unit/test_port_state.sh - fourth-round regression: the listen-state
# report must never turn "cannot observe" into "is listening".
#
# F14  s5_port_free is deliberately fail-closed: with neither `ss` nor `netstat`
#      available it warns and reports "not free". s5_port_listening negated that
#      answer, so the fail-closed "not free" became an affirmative "listening",
#      and `status` printed
#          port      : listening on 0.0.0.0:31080
#      one line after warning that it could not determine the port state at all.
#      That is the mirror image of F4 (a non-root `status` claiming the firewall
#      rule had vanished when it merely could not check it). The remedy is a
#      tri-state: 0 listening, 1 not listening, 2 unobservable.
#
#      The same inversion made the install-time verification fail OPEN: `if !
#      s5_port_listening` treated "cannot observe" as a passed check. That path
#      is not reachable today, because both s5_prompt_port and s5_random_port
#      call the same fail-closed s5_port_free and abort the install long before
#      the verification step, so it is proven structurally here rather than with
#      a functional case that cannot be constructed.

S5T_NAME=test_port_state
. "${S5_REPO_ROOT}/tests/lib/assert.sh"
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
. "${S5_REPO_ROOT}/tests/lib/env.sh"

s5env_setup
s5env_load

mkdir -p "$S5_UNITDIR"

# ==========================================================================
# Happy path: both callers still behave when the state IS observable.
# ==========================================================================
t_run s5env_full_install 31080 portuser 'PortPass_123~x'
assert_eq "a normal install passes the listen verification" 0 "$T_STATUS"
assert_file_exists "the install completed" "$S5_STATE"

# The stubbed service is running, so the probe reports the port occupied.
assert_file_exists "the stub service is active" "$S5_TEST_ROOT/svc_active"
t_run s5_cmd_status
assert_eq "status succeeds" 0 "$T_STATUS"
assert_contains "an observed listener is reported with its address" \
    "$(s5_msg status.listening 0.0.0.0 31080)" "$T_OUT"

# Stop it: the port becomes observably free.
rm -f "$S5_TEST_ROOT/svc_active"
t_run s5_cmd_status
assert_eq "status succeeds with the service stopped" 0 "$T_STATUS"
assert_contains "an observed absence uses the catalog's not-listening value" \
    "$(s5_msg status.not_listening 31080)" "$T_OUT"

# ==========================================================================
# The tri-state contract itself.
# ==========================================================================
S5_PORT=31080
t_run s5_port_listening
assert_eq "an observably free port is status 1 (not listening)" 1 "$T_STATUS"

printf '31080\n' >"$S5_TEST_ROOT/svc_active"
t_run s5_port_listening
assert_eq "an observably occupied port is status 0 (listening)" 0 "$T_STATUS"

# The production-first /proc adapter needs no iproute package.
printf '  sl  local_address rem_address   st\n   0: 00000000:9C40 00000000:0000 0A\n   1: 0100007F:A078 00000000:0000 0A\n' >"$S5_PROC_NET_TCP"
printf '  sl  local_address remote_address   st\n' >"$S5_PROC_NET_TCP6"
t_run s5_proc_port_free 40000
assert_eq "/proc adapter finds a wildcard listener" 1 "$T_STATUS"
t_run s5_proc_port_free 41080 127.0.0.1
assert_eq "/proc adapter finds an exact loopback listener" 1 "$T_STATUS"
t_run s5_proc_port_free 41081
assert_eq "/proc adapter reports an unused port free" 0 "$T_STATUS"
assert_eq "IPv4 conversion matches Linux socket-table order" 0100007F \
    "$(s5_ipv4_to_proc_hex 127.0.0.1)"

printf '' >"$S5_PROC_NET_TCP"
t_run s5_proc_port_free 41081
assert_eq "empty proc table is unobservable, never free" 2 "$T_STATUS"
printf 'bad header\n' >"$S5_PROC_NET_TCP"
t_run s5_proc_port_free 41081
assert_eq "malformed proc table is unobservable" 2 "$T_STATUS"
printf '  sl  local_address rem_address   st\n   0: malformed 00000000:0000 0A\n' >"$S5_PROC_NET_TCP"
t_run s5_proc_port_free 41081
assert_eq "malformed proc socket row is unobservable" 2 "$T_STATUS"
printf '  sl  local_address rem_address   st\n' >"$S5_PROC_NET_TCP"
printf 'bad header\n' >"$S5_PROC_NET_TCP6"
t_run s5_proc_port_free 41081
assert_eq "malformed tcp6 table also fails closed" 2 "$T_STATUS"
printf '  sl  local_address remote_address   st\n' >"$S5_PROC_NET_TCP6"

# ==========================================================================
# The adapter must validate the tables the KERNEL writes, not the ones this
# suite fabricates.
#
# net/ipv4/tcp_ipv4.c prints the third header column as "rem_address";
# net/ipv6/tcp_ipv6.c prints it as "remote_address". Requiring the IPv4
# spelling of both made s5_proc_net_available answer "unobservable" on every
# host where /proc/net/tcp6 exists -- i.e. everything but ipv6.disable=1 -- so
# the adapter that exists precisely so no iproute package is needed never ran
# in production, and s5_runtime_deps planned iproute2 on hosts that did not
# need it. Every tcp6 fixture in this suite wrote the IPv4 spelling, so no
# fixture could ever have caught this; only the real table can.
# ==========================================================================
if [ -r /proc/net/tcp ] && [ -r /proc/net/tcp6 ]; then
    t_run s5_proc_table_valid /proc/net/tcp
    assert_eq "the kernel's own IPv4 socket table validates" 0 "$T_STATUS"
    t_run s5_proc_table_valid /proc/net/tcp6
    assert_eq "the kernel's own IPv6 socket table validates" 0 "$T_STATUS"
    _pps_tcp=$S5_PROC_NET_TCP
    _pps_tcp6=$S5_PROC_NET_TCP6
    S5_PROC_NET_TCP=/proc/net/tcp
    S5_PROC_NET_TCP6=/proc/net/tcp6
    t_run s5_proc_net_available
    assert_eq "the kernel's socket tables are observable" 0 "$T_STATUS"
    assert_eq "proc stays the preferred probe against the real tables" proc \
        "$(s5_probe_cmd)"
    S5_PROC_NET_TCP=$_pps_tcp
    S5_PROC_NET_TCP6=$_pps_tcp6
else
    t_skip "the kernel's own socket tables validate" \
        "/proc/net/tcp6 is not readable on this host"
fi

# Both backends must answer the SAME way about an address they cannot parse. The
# proc backend refuses it through s5_ipv4_to_proc_hex and returns 2; the
# ss/netstat backend skipped validation entirely and fell through its non-match
# path to "free", so a malformed listen address made `status` confidently report
# a running proxy as not listening. The test-mode probe short-circuits ahead of
# both backends, so only the source can witness the ss half.
_pf_body=$(sed -n '/^s5_port_free() {/,/^}/p' "${S5_SRC}")
assert_contains "the ss backend validates the address it was given" \
    "s5_ipv4_is_canonical" "$_pf_body"
t_run s5_proc_port_free 41081 0.0.0.0/8
assert_eq "the proc backend calls a malformed address unobservable" 2 "$T_STATUS"
t_run s5_proc_port_free 41081 999.0.0.1
assert_eq "the proc backend refuses an out-of-range octet" 2 "$T_STATUS"

# ==========================================================================
# The answer must be about the port asked for, not about the service.
#
# The stub probe short-circuited on the existence of svc_active before it ever
# read $1, so while the service ran EVERY port answered "listening". That made
# the two cases above pass for a caller that probed a hardcoded port, the wrong
# variable, or no port at all -- the oracle could not see the difference. The
# stub now records which port came up, so a port nothing is listening on has to
# report free even while the service is running.
# ==========================================================================
assert_eq "the service is recorded as up on a specific port" \
    31080 "$(cat "$S5_TEST_ROOT/svc_active")"
S5_PORT=31081
t_run s5_port_listening
assert_eq "a DIFFERENT port is not listening, though the service is up" \
    1 "$T_STATUS"
t_run s5_port_free 31081
assert_eq "and s5_port_free agrees that other port is free" 0 "$T_STATUS"
t_run s5_port_free 31080
assert_ne "while the service's own port is not free" 0 "$T_STATUS"

# status must follow the port it was configured with, not the service state.
S5_PORT=31080
t_run s5_cmd_status
assert_contains "status reports the configured port as listening" \
    "$(s5_msg status.listening 0.0.0.0 31080)" "$T_OUT"
rm -f "$S5_TEST_ROOT/svc_active"

# ==========================================================================
# Structural: neither caller may negate the function, because a bare negation
# maps the unobservable status onto one of the two definite answers.
#
# The install verification moved into s5_wait_listening (a bounded poll: the
# unit is Type=simple, so the manager reports active before the socket is
# bound). Every property the old install-step assertions guarded moved with
# it and is asserted where the code now lives.
# ==========================================================================
steps=$(sed -n '/^s5_install_steps() {/,/^}/p' "${S5_SRC}")
wait_fn=$(sed -n '/^s5_wait_listening() {/,/^}/p' "${S5_SRC}")
verify_fn=$(sed -n '/^s5_verify_running_config() {/,/^}/p' "${S5_SRC}")
status_fn=$(sed -n '/^_s5_cmd_status_locked() {/,/^}/p' "${S5_SRC}")
# Comments are excluded: the fix documents the old bug by quoting it.
code_only() { grep -v '^[[:space:]]*#'; }

assert_ne "s5_wait_listening is defined" "" "$wait_fn"
if printf '%s\n' "$wait_fn" | code_only | grep -q 'if ! s5_port_listening'; then
    t_bad "the wait must not negate s5_port_listening: a bare
negation reads 'cannot observe' as 'verified listening'"
else
    t_ok
fi
if printf '%s\n' "$status_fn" | code_only | grep -qE 'if s5_port_listening;? *then'; then
    t_bad "status must not branch two ways on a three-valued answer"
else
    t_ok
fi
assert_contains "the install step uses shared running-config verification" \
    "s5_verify_running_config" "$steps"
assert_contains "shared verification checks the listener" \
    "s5_wait_listening" "$verify_fn"
assert_contains "the wait observes the port through the tri-state probe" \
    "s5_port_listening" "$wait_fn"
assert_contains "and refuses when the listen state cannot be observed" \
    "s5_err_msg service.wait_no_probe" "$wait_fn"
assert_contains "status reports the unobservable case through the catalog" \
    "status.listen_unverified" "$status_fn"

# Drift guard: the availability probe must gate on exactly the same conditions
# as s5_port_free, or the two can disagree about whether a probe exists.
free_fn=$(sed -n '/^s5_port_free() {/,/^}/p' "${S5_SRC}")
avail_fn=$(sed -n '/^s5_port_probe_available() {/,/^}/p' "${S5_SRC}")
assert_ne "s5_port_probe_available exists" "" "$avail_fn"
for pat in 'S5_TEST_MODE:-0' 'S5_PORT_PROBE:-' 's5_probe_cmd'; do
    assert_contains "s5_port_free gates on $pat" "$pat" "$free_fn"
    assert_contains "s5_port_probe_available gates on the same $pat" "$pat" "$avail_fn"
done

# ==========================================================================
# The PRODUCTION port match, not the stub's.
#
# Everything above runs through $S5_PORT_PROBE, so the branch that actually
# ships -- grepping real `ss -ltn` output for "[:.]<port><whitespace>" -- had no
# oracle at all locally: replacing that pattern with a bare "LISTEN" search left
# the whole file green. Emptying S5_PORT_PROBE drops s5_port_free through to the
# real branch, and `ss` is shadowed with canned output so no port is opened and
# nothing about the host is assumed.
#
# The substring cases are the reason the pattern is shaped the way it is: 1080 is
# a suffix of 31080, 310 is a prefix, and 4096 appears in the Send-Q column of a
# listening row. All three must read as FREE.
# ==========================================================================
S5_PORT_PROBE=''
export S5_PORT_PROBE
s5_probe_cmd() { printf 'ss'; return 0; }
ss() {
    cat <<'SSOUT'
State  Recv-Q Send-Q Local Address:Port   Peer Address:Port Process
LISTEN 0      4096         0.0.0.0:31080        0.0.0.0:*
LISTEN 0      4096       127.0.0.1:22           0.0.0.0:*
SSOUT
}

t_run s5_port_free 31080
assert_ne "production: a port in the ss output is not free" 0 "$T_STATUS"
t_run s5_port_free 22
assert_ne "production: a second listening port is also seen" 0 "$T_STATUS"
t_run s5_port_free 31081
assert_eq "production: a port absent from the ss output is free" 0 "$T_STATUS"
t_run s5_port_free 1080
assert_eq "production: a SUFFIX of a listening port is free (1080 vs 31080)" \
    0 "$T_STATUS"
t_run s5_port_free 310
assert_eq "production: a PREFIX of a listening port is free (310 vs 31080)" \
    0 "$T_STATUS"
t_run s5_port_free 4096
assert_eq "production: a number from another column is not a listening port" \
    0 "$T_STATUS"

# The same three-valued answer, through the production branch.
S5_PORT=31080
t_run s5_port_listening
assert_eq "production: the listening port reports 0" 0 "$T_STATUS"
S5_PORT=31081
t_run s5_port_listening
assert_eq "production: a free port reports 1" 1 "$T_STATUS"

# Prompt-time collision detection remains port-only (a listener on any address
# occupies the port), but readiness/status must prove the configured address.
ss() {
    cat <<'SSOUT'
State  Recv-Q Send-Q Local Address:Port   Peer Address:Port Process
LISTEN 0      4096       127.0.0.1:31080        0.0.0.0:*
SSOUT
}
S5_LISTEN=0.0.0.0
S5_PORT=31080
t_run s5_port_free 31080
assert_ne "production: port-only collision sees a listener on another address" 0 "$T_STATUS"
t_run s5_port_free 31080 0.0.0.0
assert_eq "production: address-aware probe rejects a same-port address mismatch" 0 "$T_STATUS"
t_run s5_port_listening
assert_eq "production: readiness rejects a listener on the wrong address" 1 "$T_STATUS"
t_run s5_cmd_status
assert_not_contains "status never prints an address it did not observe" \
    "$(s5_msg status.listening 0.0.0.0 31080)" "$T_OUT"

# netstat uses the same fourth-field Local Address contract.
s5_probe_cmd() { printf 'netstat'; return 0; }
netstat() {
    cat <<'NETOUT'
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 127.0.0.1:31080         0.0.0.0:*               LISTEN
NETOUT
}
t_run s5_port_free 31080 0.0.0.0
assert_eq "netstat: address-aware probe rejects a same-port mismatch" 0 "$T_STATUS"

# A probe command that exists but fails is also unobservable; empty output must
# never be interpreted as proof that the port is free.
s5_probe_cmd() { printf 'ss'; return 0; }
ss() { return 1; }
S5_PORT=31080
t_run s5_port_free 31080
assert_ne "production: a failed ss command is not treated as free" 0 "$T_STATUS"
t_run s5_port_listening
assert_eq "production: a failed ss command is unobservable" 2 "$T_STATUS"

unset -f ss
unset -f s5_probe_cmd
S5_PORT=31080

# ==========================================================================
# THE REGRESSION: no probe at all.
#
# The selector is shadowed rather than emptying PATH, because busybox ships
# netstat as a built-in applet that PATH manipulation cannot hide. This is
# one-way, so it comes last.
# ==========================================================================
S5_PORT_PROBE=''
export S5_PORT_PROBE
s5_probe_cmd() { return 1; }

t_run s5_port_probe_available
assert_eq "with no ss and no netstat, no probe is available" 1 "$T_STATUS"

t_run s5_port_listening
assert_eq "an unobservable port is status 2, not 0" 2 "$T_STATUS"
assert_eq "and the unobservable path says nothing about being free" "" "$T_OUT"

t_run s5_cmd_status
assert_eq "status still succeeds without a probe" 0 "$T_STATUS"
assert_not_contains "status never claims a listener it could not observe" \
    "$(s5_msg status.listening 0.0.0.0 31080)" "$T_OUT"
assert_contains "status uses the catalog's unverified listen value" \
    "$(s5_msg status.listen_unverified 31080)" "$T_OUT"
assert_not_contains "status does not emit the contradictory port-free warning" \
    "$(s5_msg network.port_free_unknown 31080)" "$T_OUT"

# The value, not just the label, must follow the per-invocation locale.
S5_LANG=zh
t_run s5_cmd_status
assert_eq "Chinese status succeeds without a probe" 0 "$T_STATUS"
assert_contains "Chinese status localizes the heading" \
    "$(s5_msg status.heading "$S5_PROJECT")" "$T_OUT"
assert_contains "Chinese status localizes the unverified listen value" \
    "$(s5_msg status.listen_unverified 31080)" "$T_OUT"
assert_not_contains "Chinese status leaks no old English listen value" \
    "listen state not verified" "$T_OUT"

t_summary
