#!/bin/sh
# tests/lib/env.sh - shared harness for the install/lifecycle tests.
# Builds a fully stubbed, sandboxed environment so that no real service,
# account, firewall rule or system path is ever touched.

s5env_setup() {
    t_mktestroot
    t_stub_init

    for s in git make systemctl curl; do
        cp "${S5_REPO_ROOT}/tests/stubs/$s" "$S5_TEST_ROOT/bin/$s"
        chmod 0755 "$S5_TEST_ROOT/bin/$s"
    done

    # Everything privileged is a recording stub.
    t_stub rc-service 0
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
    : >"$S5_TEST_ROOT/occupied"
    cat >"$S5_TEST_ROOT/bin/portprobe" <<'PROBE'
#!/bin/sh
if [ -z "${1:-}" ]; then
    printf 'portprobe: called with no port argument\n' >&2
    exit 2
fi
if [ -f "$S5_TEST_ROOT/svc_active" ]; then
    _active=$(cat "$S5_TEST_ROOT/svc_active" 2>/dev/null)
    # An empty svc_active means a test marked the service up without going
    # through the stub, and no port is known. Keep the old catch-all meaning
    # for that case only, so existing lifecycle tests keep their semantics.
    if [ -z "$_active" ] || [ "$_active" = "$1" ]; then exit 1; fi
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
    export S5_STUB_CFG S5_STUB_UNIT
}

# s5env_answers <text> : queue interactive answers, consumed via redirection.
s5env_answers() {
    printf '%s' "$1" >"$S5_TEST_ROOT/answers"
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

# s5env_full_install : drive a complete successful install with the given
# port/user/password, answering yes to dependencies and no/yes to the firewall.
s5env_full_install() {
    s5env_answers "y
$1
$2
$3
$3
y
${4:-y}
"
    printf '%s:%s' "$2" "$3" >"$S5_TEST_ROOT/expected_creds"
    s5_cmd_install <"$S5_TEST_ROOT/answers"
}
