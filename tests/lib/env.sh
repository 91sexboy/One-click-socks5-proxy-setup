#!/bin/sh
# tests/lib/env.sh - shared harness for the install/lifecycle tests.
# Builds a fully stubbed, sandboxed environment so that no real service,
# account, firewall rule or system path is ever touched.

s5env_setup() {
    t_mktestroot
    t_stub_init

    for s in git make systemctl rc-service curl; do
        cp "${S5_REPO_ROOT}/tests/stubs/$s" "$S5_TEST_ROOT/bin/$s"
        chmod 0755 "$S5_TEST_ROOT/bin/$s"
    done

    # Everything privileged is a recording stub.
    t_stub rc-update 0
    t_stub chown 0
    t_stub logger 0
    t_stub ufw 0 "Status: inactive"
    t_stub firewall-cmd 1 "not running"
    t_stub iptables 1
    t_stub nft 1

    s5env_setup_pkgmgrs
    s5env_account_stubs

    # Port probe. A port counts as occupied when the (stubbed) service is
    # listening ON THAT PORT, or when it is listed in $S5_TEST_ROOT/occupied.
    #
    # The port comparison is the point. This used to short-circuit on the mere
    # existence of svc_active, before ever reading $1, so while the service ran
    # EVERY port answered "occupied" -- a caller that probed the wrong port, or
    # ignored its argument entirely, could not be caught. Production greps the
    # real ss/netstat output for the specific port, so the stub has to be at
    # least as discriminating or the tests are weaker than the code they guard.
    #
    # Late bind (fix-plan Task 1): with $S5_TEST_ROOT/svc_latebind holding N,
    # the first N observations of the service's own port answer "free" while
    # the service is already active -- the deterministic model of a Type=simple
    # unit (or an OpenRC service under supervise-daemon) whose socket is not
    # bound yet. Counted separately in svc_latebind_seen, so the delay is
    # measured in observations of THAT port, not in total probe invocations
    # (the port prompt probes before the service exists and must not consume
    # the budget). A test that never removes the file models a port that never
    # binds within any window.
    #
    # port_probe_count is the opt-in tally of every invocation: a test creates
    # (or truncates) the file to start counting, which is how "waited the whole
    # window" and "failed fast, long before the window" are proven from disk
    # without any real clock.
    : >"$S5_TEST_ROOT/occupied"
    cat >"$S5_TEST_ROOT/bin/portprobe" <<'PROBE'
#!/bin/sh
if [ -z "${1:-}" ]; then
    printf 'portprobe: called with no port argument\n' >&2
    exit 2
fi
if [ -f "$S5_TEST_ROOT/port_probe_count" ]; then
    _n=$(cat "$S5_TEST_ROOT/port_probe_count" 2>/dev/null)
    case "$_n" in '' | *[!0-9]*) _n=0 ;; esac
    _n=$((_n + 1))
    printf '%s\n' "$_n" >"$S5_TEST_ROOT/port_probe_count"
fi
if [ -f "$S5_TEST_ROOT/svc_active" ]; then
    _active=$(cat "$S5_TEST_ROOT/svc_active" 2>/dev/null)
    # An empty svc_active means a test marked the service up without going
    # through the stub, and no port is known. Keep the old catch-all meaning
    # for that case only, so existing lifecycle tests keep their semantics.
    if [ -z "$_active" ] || [ "$_active" = "$1" ]; then
        # Port-only callers model collision detection: a listener on any address
        # makes the port busy. Readiness/status callers pass the configured
        # address as $2 and must see that exact address, not merely the port.
        if [ -n "${2:-}" ] && [ -n "$_active" ]; then
            _listen=0.0.0.0
            if [ -f "$S5_TEST_ROOT/svc_listen" ]; then
                _listen=$(cat "$S5_TEST_ROOT/svc_listen" 2>/dev/null)
            fi
            [ "$_listen" = "$2" ] || exit 0
        fi
        if [ "$_active" = "$1" ] && [ -f "$S5_TEST_ROOT/svc_latebind" ]; then
            _late=$(cat "$S5_TEST_ROOT/svc_latebind" 2>/dev/null)
            case "$_late" in '' | *[!0-9]*) _late=0 ;; esac
            _seen=$(cat "$S5_TEST_ROOT/svc_latebind_seen" 2>/dev/null)
            case "$_seen" in '' | *[!0-9]*) _seen=0 ;; esac
            _seen=$((_seen + 1))
            printf '%s\n' "$_seen" >"$S5_TEST_ROOT/svc_latebind_seen"
            if [ "$_seen" -le "$_late" ]; then
                exit 0
            fi
        fi
        exit 1
    fi
fi
if grep -qx "$1" "$S5_TEST_ROOT/occupied" 2>/dev/null; then exit 1; fi
exit 0
PROBE
    chmod 0755 "$S5_TEST_ROOT/bin/portprobe"

    printf '%s\n' da99424eac4092e3722f1a5b1844cfe80478f580 >"$S5_TEST_ROOT/stub_head"

    S5_TEST_MODE=1
    S5_LIB_ONLY=1
    S5_PORT_PROBE="$S5_TEST_ROOT/bin/portprobe"
    S5_OSRELEASE="${S5_REPO_ROOT}/tests/fixtures/os-release/debian-12"
    S5_ASSUME_ROOT=1
    S5_SKIP_OWNERSHIP=1
    export S5_TEST_MODE S5_LIB_ONLY S5_PORT_PROBE S5_OSRELEASE S5_ASSUME_ROOT S5_SKIP_OWNERSHIP
}

s5env_setup_pkgmgrs() {
    t_stub apt-get 0
    t_stub apk 0
    t_stub dnf 0
}

# Stateful account tools: existence genuinely changes when create/delete works.
s5env_account_stubs() {
    for n in id useradd userdel adduser deluser groupadd groupdel addgroup delgroup getent; do
        cp "${S5_REPO_ROOT}/tests/stubs/account" "$S5_TEST_ROOT/bin/$n"
        chmod 0755 "$S5_TEST_ROOT/bin/$n"
    done
    : >"$S5_TEST_ROOT/stub_passwd"
    : >"$S5_TEST_ROOT/stub_group"
}

# s5env_load : source socks5.sh in library mode and point the stubs at the
# resolved config/unit paths.
s5env_load() {
    # shellcheck source=/dev/null
    . "${S5_SRC}"
    S5_STUB_CFG="$S5_CFG"
    S5_STUB_UNIT="$S5_UNIT"
    S5_STUB_INITSCRIPT="$S5_INITSCRIPT"
    export S5_STUB_CFG S5_STUB_UNIT S5_STUB_INITSCRIPT
}

# s5env_answers <text> : queue interactive answers, consumed via redirection.
# 0600 like the install builders: these streams carry no password today, but
# one uniform mode means no answer file is ever group- or world-readable.
s5env_answers() {
    printf '%s' "$1" >"$S5_TEST_ROOT/answers"
    chmod 0600 "$S5_TEST_ROOT/answers"
}

s5env_reset_transcript() {
    : >"$T_TRANSCRIPT"
    : >"$S5_TEST_ROOT/curl_stdin"
}

# s5env_line_of <pattern> : 1-based transcript line number of the first match, or 0.
s5env_line_of() {
    _n=$(t_transcript | grep -n -- "$1" | head -n 1 | cut -d: -f1)
    if [ -z "$_n" ]; then printf '0'; else printf '%s' "$_n"; fi
}

# s5env_install_answers <confirm> <port> <user> <password> : the ONE builder
# for a complete install's interactive input in LIBRARY mode -- a direct
# s5_cmd_install call. The selector never runs there (it is dispatched from
# s5_main, which S5_LIB_ONLY sourcing skips), so the stream starts at the
# confirmation and queues exactly four lines: confirm, port, username and
# the custom password -- once; a second copy would silently mask a
# regression back to the removed confirmation read. No trailing lines: the
# y/n answers of the firewall and dependency prompts retired in round 10
# are gone with those prompts. Callers that assert on locale set S5_LANG
# themselves (sourcing defaults it to en); the language is a variable here,
# never a queued line.
s5env_install_answers() {
    printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" >"$S5_TEST_ROOT/answers"
    chmod 0600 "$S5_TEST_ROOT/answers"
}

# s5env_install_cli <lang> <confirm> <port> <user> <password> : the builder
# for a REAL-PROCESS install (`sh socks5.sh install`). s5_main selects the
# language before dispatching the command, so this stream is the selector's
# answer (blank or 1 = zh, 2 = en) followed by the same four install lines
# as the library builder. Queueing the selector answer into a library-mode
# stream instead would feed it to the [Y/n] confirmation as an invalid
# entry -- the install would still succeed, on the retry.
s5env_install_cli() {
    printf '%s\n%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" "$5" \
        >"$S5_TEST_ROOT/answers"
    chmod 0600 "$S5_TEST_ROOT/answers"
}

# s5env_full_install <port> <user> <password> : drive a complete successful
# install (library mode) with the given port/user/password. The language is
# pinned here, not queued: no selector runs in library mode, so a language
# line in the stream would be consumed by the confirmation prompt as an
# invalid answer and every caller would silently pass on the retry path.
s5env_full_install() {
    S5_LANG=${S5_LANG:-en}
    s5env_install_answers y "$1" "$2" "$3"
    printf '%s:%s' "$2" "$3" >"$S5_TEST_ROOT/expected_creds"
    s5_cmd_install <"$S5_TEST_ROOT/answers"
}
