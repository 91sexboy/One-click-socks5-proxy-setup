#!/bin/sh
# Shared fixtures, bounded waits and credential checks for native lifecycle gates.
#
# lifecycle_write_fixtures <workdir>: write the install and in-place-update answer
# and password files into <workdir> and lock them to 0600. The in-place update
# rotates to ciuser2/CISecret456y on the same port, which each gate then asserts
# landed in the config and the state.
lifecycle_write_fixtures() {
    _lcw=$1
    printf 'ciuser\nCISecret123x\n' >"$_lcw/pass"
    printf 'ciuser2\nCISecret456y\n' >"$_lcw/pass.update"
    { printf '2\ny\n23456\n'; cat "$_lcw/pass"; } >"$_lcw/answers"
    { printf 'y\n23456\n'; cat "$_lcw/pass"; } >"$_lcw/answers.reinstall"
    { printf 'y\n23456\n'; cat "$_lcw/pass.update"; } >"$_lcw/answers.update"
    : >"$_lcw/answers.empty"
    printf 'y\n' >"$_lcw/answers.uninstall"
    chmod 0600 "$_lcw/answers" "$_lcw/answers.reinstall" "$_lcw/pass" "$_lcw/answers.update" "$_lcw/pass.update" \
        "$_lcw/answers.empty" "$_lcw/answers.uninstall"
}

lifecycle_wait_until() {
    _lcwu_attempts=$1
    _lcwu_interval=$2
    shift 2
    _lcwu_count=0
    while [ "$_lcwu_count" -lt "$_lcwu_attempts" ]; do
        _lcwu_count=$((_lcwu_count + 1))
        if "$@"; then return 0; fi
        sleep "$_lcwu_interval"
    done
    return 1
}

# lifecycle_ready_or_exited <readyfile> <pid>: the wait condition for a
# launcher, true once <readyfile> is non-empty or <pid> has exited. It ends a
# wait, it does not judge it: the caller still requires the marker and a live
# process afterwards, so an early exit is never read as readiness.
lifecycle_ready_or_exited() {
    test -s "$1" || ! kill -0 "$2" 2>/dev/null
}

# lifecycle_start_duplex_target <dir>: start the duplex target on every address,
# so one listener answers at both the permitted 192.0.2.1 and the denied
# 127.0.0.1 -- the boundary case needs a live listener at the denied address, or
# a refusal would only prove that nothing was listening there. Waits for its
# port in <dir>/target.port and sets target_pid and target_port.
lifecycle_start_duplex_target() {
    python3 tests/protocol/duplex_target.py --host 0.0.0.0 --host6 :: \
        --ready-file "$1/target.port" --count-file "$1/count" \
        --report-file "$1/report" >"$1/target.log" 2>&1 &
    target_pid=$!
    # The port is checked once more after the wait: it can arrive during the
    # final sleep, which an exhausted wait does not observe.
    lifecycle_wait_until 50 0.1 test -s "$1/target.port" || true
    if ! test -s "$1/target.port"; then
        printf 'the duplex target never reported its port\n' >&2
        return 1
    fi
    target_port=$(cat "$1/target.port")
}

lifecycle_no_credential_in() {
    _lcn_file=$1
    _lcn_secret=$2
    shift 2
    _lcn_status=0
    printf '%s\n' "$_lcn_secret" | "$@" grep -qFf - "$_lcn_file" 2>/dev/null || _lcn_status=$?
    case "$_lcn_status" in
    1) return 0 ;;
    0) printf 'a credential reached %s\n' "$_lcn_file" >&2 ;;
    *) printf 'the credential check on %s failed with status %s\n' "$_lcn_file" "$_lcn_status" >&2 ;;
    esac
    return 1
}

lifecycle_generation_absent() {
    _lga_log=$1
    _lga_file=$2
    shift 2
    if [ "$#" -gt 0 ]; then
        _lga_user=$("$@" sed -n '1p' "$_lga_file") || return 1
        _lga_pass=$("$@" sed -n '2p' "$_lga_file") || return 1
    else
        _lga_user=$(sed -n '1p' "$_lga_file") || return 1
        _lga_pass=$(sed -n '2p' "$_lga_file") || return 1
    fi
    [ -n "$_lga_user" ] && [ -n "$_lga_pass" ] || return 1
    _lga_pair=$_lga_user:$_lga_pass
    _lga_encoded=$(printf '%s' "$_lga_pair" | base64 | tr -d '\n') || return 1
    lifecycle_no_credential_in "$_lga_log" "$_lga_pass" "$@" || return 1
    lifecycle_no_credential_in "$_lga_log" "$_lga_pair" "$@" || return 1
    lifecycle_no_credential_in "$_lga_log" "$_lga_encoded" "$@" || return 1
    _lga_user=''; _lga_pass=''; _lga_pair=''; _lga_encoded=''
}

lifecycle_assert_logs_redacted() {
    _lalr_work=$1
    shift
    # Each command log is checked against every credential generation that
    # existed when the command ran. Username alone remains operator-visible.
    lifecycle_generation_absent "$_lalr_work/install.log" "$_lalr_work/pass" "$@" || return 1
    for _lalr_log in update.log status.log restart.log uninstall.log uninstall-second.log; do
        lifecycle_generation_absent "$_lalr_work/$_lalr_log" "$_lalr_work/pass" "$@" || return 1
        lifecycle_generation_absent "$_lalr_work/$_lalr_log" "$_lalr_work/pass.update" "$@" || return 1
    done
    lifecycle_generation_absent "$_lalr_work/reinstall.log" "$_lalr_work/pass" "$@" || return 1
    lifecycle_generation_absent "$_lalr_work/uninstall-reinstall.log" "$_lalr_work/pass" "$@" || return 1
}

# lifecycle_redaction_file <out> <passfile...>: write every form a log can carry
# each credential in -- the password, user:pass, and its base64 -- to the
# private pattern file <out>, one per line. The patterns travel only through
# files, never argv or the environment.
lifecycle_redaction_file() {
    _lrf_out=$1
    shift
    : >"$_lrf_out" || return 1
    for _lrf_file do
        if [ ! -f "$_lrf_file" ] ||
            ! awk 'NR == 2 {print} NR <= 2 && length($0) == 0 {bad = 1} END {exit (NR < 2 || bad) ? 1 : 0}' \
                "$_lrf_file" >>"$_lrf_out" 2>/dev/null; then
            return 1
        fi
        _lrf_user=$(sed -n '1p' "$_lrf_file") || return 1
        _lrf_pass=$(sed -n '2p' "$_lrf_file") || return 1
        _lrf_pair=$_lrf_user:$_lrf_pass
        printf '%s\n' "$_lrf_pair" >>"$_lrf_out" || return 1
        printf '%s' "$_lrf_pair" | base64 | tr -d '\n' >>"$_lrf_out" || return 1
        printf '\n' >>"$_lrf_out" || return 1
        _lrf_user=''; _lrf_pass=''; _lrf_pair=''
    done
}

# lifecycle_redact <patternfile>: copy stdin to stdout with every pattern
# replaced by <REDACTED>. The longest literal wins at each position, and
# replacement markers are not filtered again, so a rotated credential that
# extends an earlier one is hidden whole. Every CI log exit uses this one form:
# dropping matching lines instead also dropped the evidence around a secret.
lifecycle_redact() {
    awk '
        BEGIN {
            while ((loaded = getline secret < ARGV[1]) > 0) {
                if (secret == "") exit 2
                secrets[++count] = secret
            }
            if (loaded < 0 || count < 2) exit 2
            close(ARGV[1]); ARGV[1] = ""
        }
        function hide(text, result, i, at, first, width) {
            result = ""
            while (length(text)) {
                first = 0; width = 0
                for (i = 1; i <= count; i++) {
                    at = index(text, secrets[i])
                    if (at && (!first || at < first || (at == first && length(secrets[i]) > width))) {
                        first = at; width = length(secrets[i])
                    }
                }
                if (!first) return result text
                result = result substr(text, 1, first - 1) "<REDACTED>"
                text = substr(text, first + width)
            }
            return result
        }
        {print hide($0)}
    ' "$1"
}

# lifecycle_process_clean <pid> <copydir> <passfile...>: prove no credential
# form reaches the process's argv or environment. Each /proc file is copied
# first, so one that cannot be read fails the check (2) instead of feeding an
# empty stream to grep, which then "passed"; the credentials come from their
# private files, never a command line. Returns 1 on a leak.
lifecycle_process_clean() {
    _lpc_pid=$1
    _lpc_dir=$2
    shift 2
    for _lpc_part in cmdline environ; do
        if ! tr '\0' '\n' <"/proc/$_lpc_pid/$_lpc_part" >"$_lpc_dir/process.$_lpc_part"; then
            printf 'the credential check could not read /proc/%s/%s\n' "$_lpc_pid" "$_lpc_part" >&2
            return 2
        fi
        # A live process always has an argv; an empty copy observed nothing.
        if [ "$_lpc_part" = cmdline ] && [ ! -s "$_lpc_dir/process.cmdline" ]; then
            printf 'the credential check read an empty argv for pid %s\n' "$_lpc_pid" >&2
            return 2
        fi
        for _lpc_file do
            lifecycle_generation_absent "$_lpc_dir/process.$_lpc_part" "$_lpc_file" || return 1
        done
    done
    rm -f "$_lpc_dir/process.cmdline" "$_lpc_dir/process.environ"
}

# lifecycle_assert_ready_status <log> <port> [prefix...]: a healthy status is
# informational, so output rather than a zero exit proves readiness. The
# heading carries "mixed" on its own, which let a listener degraded to
# service.listen or service.unverified pass: require the service.ready line for
# the port and the protocol summary of the status line.
lifecycle_assert_ready_status() {
    _lars_log=$1
    _lars_port=$2
    shift 2
    if ! "$@" grep -qxF "Xray is listening on port $_lars_port." "$_lars_log"; then
        printf 'status did not report port %s ready\n' "$_lars_port" >&2
        return 1
    fi
    if ! "$@" grep -qF 'protocol: mixed (SOCKS5 + HTTP); auth: password; UDP: disabled' "$_lars_log"; then
        printf 'status lost its protocol summary\n' >&2
        return 1
    fi
}

# lifecycle_assert_exited_status <status> <log> <state> <port> [prefix...]: a
# status run against a service the manager reports exited (OpenRC crashed,
# systemd failed) must return nonzero and name that state for the port. A zero
# exit here is exactly the false health this check exists to catch.
lifecycle_assert_exited_status() {
    _laes_status=$1
    _laes_log=$2
    _laes_state=$3
    _laes_port=$4
    shift 4
    if [ "$_laes_status" -eq 0 ]; then
        printf 'status returned 0 for a %s service\n' "$_laes_state" >&2
        return 1
    fi
    if ! "$@" grep -qF "service: $_laes_state; port: $_laes_port;" "$_laes_log"; then
        printf 'status did not name the %s service\n' "$_laes_state" >&2
        return 1
    fi
}
