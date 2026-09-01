#!/bin/sh
# tests/unit/test_probe_tooling.sh - sixth-round regressions in the test tooling
# itself. The tooling had never been under test, and every defect below made a
# *failure* look like a *pass*.
#
# F22 (HIGH)  socks_probe.py exits 1 for REFUSED, and Python exits 1 on an
#             uncaught traceback. `--port notanumber` therefore crashed into
#             exit 1, which run_protocol.sh scores as "the proxy correctly
#             refused" for five rejection cases -- including the SOCKS4 release
#             gate -- and acl_resolution.sh for all six destination-deny checks.
#             A single mistyped CI port would have turned the entire rejection
#             half of the protocol suite green without one byte being sent.
#
# F23 (HIGH)  mode_socks5 returned REFUSED when the RFC 1929 sub-negotiation
#             failed. Every caller of that mode supplies credentials it asserts
#             are valid and is asking about the *operation* (BIND, UDP
#             ASSOCIATE) or the destination ACL. If the handshake stops at
#             authentication the operation was never reached, so a mistyped
#             PASSFILE scored those rejections as passes.
#
# F24 (MED)   interrupt.py's read_until consulted its deadline only between
#             blocking os.read calls, so the timeout was unenforceable in the
#             one case it exists for: a prompt that never appears leaves the
#             child blocked on input and the parent blocked on output. The
#             deadlock burned the whole CI job timeout instead of reporting
#             which prompt was never reached.
#
# F25 (HIGH)  t_assert_never_called can only see what the transcript recorded,
#             and an unstubbed command records nothing. passwd, chpasswd and
#             sudo were stubbed nowhere, so six assertions guarding "no password
#             is ever set on the service account" and "no sudo" could not fail
#             -- and the invocation they were guarding against would have run
#             the real binary on the machine running the suite.
#
# F26 (HIGH)  ...and a PATH stub does not fix that under busybox, which resolves
#             passwd, chpasswd and su to built-in applets whatever PATH says. On
#             the busybox CI cell those three -- the three that matter most --
#             stayed unobservable, and `passwd --probe` reached the real applet.
#             The interception is now a shell function, and the harness proves it
#             works before any test depends on it.
#
# Nothing here binds or connects to a real port. The socket is injected.

S5T_NAME=test_probe_tooling
. "${S5_REPO_ROOT}/tests/lib/assert.sh"

R="${S5_REPO_ROOT}"
PROBE="$R/tests/protocol/socks_probe.py"
ITR="$R/tests/pty/interrupt.py"

assert_file_exists "the SOCKS probe tool is present" "$PROBE"
assert_file_exists "the PTY interrupt tool is present" "$ITR"

if ! command -v python3 >/dev/null 2>&1; then
    t_skip "probe tooling behaviour" "python3 is not available"
    t_summary
    exit 0
fi

# The three exit codes the probe promises. Re-read from the source rather than
# hardcoded, so a renumbering cannot silently invalidate this whole file.
p_granted=$(grep -E '^GRANTED = ' "$PROBE" | cut -d' ' -f3)
p_refused=$(grep -E '^REFUSED = ' "$PROBE" | cut -d' ' -f3)
p_error=$(grep -E '^ERROR = ' "$PROBE" | cut -d' ' -f3)
assert_eq "GRANTED is 0" 0 "$p_granted"
assert_eq "REFUSED is 1" 1 "$p_refused"
assert_eq "ERROR is 2" 2 "$p_error"

# ==========================================================================
# F22: a malformed argument is the probe's own fault -- ERROR, never REFUSED.
#
# These runs never reach a socket: port_arg rejects the value during argument
# parsing, before connect() is attempted.
# ==========================================================================
bad_arg() {
    printf 'u\np\n' | python3 "$PROBE" --mode socks5-connect "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

assert_eq "a non-numeric --port is an ERROR, not a refusal" \
    "$p_error" "$(bad_arg --port notanumber)"
assert_eq "a non-numeric --target-port is an ERROR" \
    "$p_error" "$(bad_arg --port 41080 --target-port notanumber)"
assert_eq "--port 0 is out of range and reported as an ERROR" \
    "$p_error" "$(bad_arg --port 0)"
assert_eq "--port 65536 is out of range" \
    "$p_error" "$(bad_arg --port 65536)"
# An out-of-range destination port used to escape as struct.error from
# struct.pack, which was not in the except tuple either.
assert_eq "--target-port 999999 is rejected before any packing" \
    "$p_error" "$(bad_arg --port 41080 --target-port 999999)"
assert_eq "an unknown --option is an ERROR" \
    "$p_error" "$(bad_arg --port 41080 --nosuchoption x)"
assert_eq "a missing --mode is an ERROR" \
    "$p_error" "$(printf 'u\np\n' | python3 "$PROBE" --port 41080 >/dev/null 2>&1; printf '%s' "$?")"

# The diagnosis has to name the offending argument, or a CI log shows only "2".
bad_msg=$(printf 'u\np\n' | python3 "$PROBE" --mode socks5-connect --port notanumber 2>&1 >/dev/null)
assert_contains "the bad argument is named in the diagnosis" "--port" "$bad_msg"
assert_not_contains "and no traceback is printed" "Traceback" "$bad_msg"

# Source-shape checks below go through grep rather than assert_contains: a
# failing assert_contains prints its entire haystack, and dumping a 300-line
# source file into the runner's output buries every other result in the suite.
src_has() { # <desc> <file> <fixed-string>
    if grep -qF -- "$3" "$2"; then t_ok; else t_bad "$1 (missing: $3)"; fi
}
src_lacks() { # <desc> <file> <fixed-string>
    if grep -qF -- "$3" "$2"; then t_bad "$1 (still present: $3)"; else t_ok; fi
}
# Code lines only. A structural guard that can be satisfied by a comment
# *describing* the thing is not a guard -- deleting the real call site then
# leaves the suite green. The forbidden-directive check in test_render.sh was
# caught by exactly this, so the comment-stripping form is a helper, not a
# one-off. Fixed-string, not an ERE: POSIX leaves `$` undefined anywhere but the
# end of an ERE, and these patterns quote shell variables.
code_has() { # <desc> <file> <fixed-string>
    if grep -v '^[[:space:]]*#' "$2" | grep -qF -- "$3"; then
        t_ok
    else
        t_bad "$1 (no code line matches: $3)"
    fi
}
code_lacks() { # <desc> <file> <fixed-string>
    if grep -v '^[[:space:]]*#' "$2" | grep -qF -- "$3"; then
        t_bad "$1 (a code line matches: $3)"
    else
        t_ok
    fi
}

# The last-resort guard must exist and must not re-raise into exit 1.
src_has "an unforeseen exception is caught at the top level" "$PROBE" "except BaseException"

# ...and it must actually work. Proven by injecting a fault of a type the
# except clause in main() does not list, into a throwaway copy: with the guard
# the process exits 2, without it the traceback exits 1 and the release gate
# reads that as a refusal. Injecting is the only honest way to test a handler
# whose whole purpose is to catch something nobody foresaw.
faultdir=$(mktemp -d)
trap 'rm -rf "$faultdir"' EXIT HUP INT TERM
python3 - "$PROBE" "$faultdir/faulty.py" <<'PYEOF'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
needle = "def main(argv):\n"
assert needle in src, "main(argv) not found in the probe"
src = src.replace(needle, needle + '    raise TypeError("injected internal fault")\n', 1)
open(sys.argv[2], "w", encoding="utf-8").write(src)
PYEOF
faulty=$(python3 "$faultdir/faulty.py" --port 41080 --mode socks5-noauth 2>&1 >/dev/null; printf '|%s' "$?")
assert_eq "an unforeseen internal fault exits ERROR, not REFUSED" \
    "$p_error" "${faulty##*|}"
assert_contains "and is labelled as the probe's own fault" "internal fault" "$faulty"
assert_contains "and names the exception type" "TypeError" "$faulty"
rm -rf "$faultdir"
trap - EXIT HUP INT TERM

# ==========================================================================
# F23: what the probe concludes from each stage of the handshake.
#
# The module is imported and its connect() replaced with a fake socket that
# replays a fixed byte stream, so every case below is exercised without opening
# a listening port or leaving the machine. recv() slices its buffer rather than
# returning it whole, which is what a real socket does and what read_exactly
# depends on.
# ==========================================================================
verdicts=$(python3 - "$PROBE" 2>&1 <<'PYEOF'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("probe_under_test", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FakeSock:
    """Replays a scripted server stream. Nothing leaves the process."""

    def __init__(self, script):
        self.buf = bytes(script)
        self.sent = b""

    def sendall(self, data):
        self.sent += data

    def recv(self, n):
        chunk, self.buf = self.buf[:n], self.buf[n:]
        return chunk

    def close(self):
        pass


def verdict(name, script, cmd=0x01, refusal="any"):
    probe.connect = lambda host, port: FakeSock(script)
    try:
        rc = probe.mode_socks5("h", 1080, "user", "pass", "example.com", 80, cmd,
                               refusal)
    except SystemExit as exc:            # die() -> sys.exit(ERROR)
        rc = exc.code
    print("%s=%s" % (name, rc))


SEL = [0x05, 0x02]                       # server selects user/password auth
AUTH_OK = [0x01, 0x00]
AUTH_FAIL = [0x01, 0x01]
IPV4_TAIL = [0, 0, 0, 0, 0, 0]           # 4 address bytes + 2 port bytes

# Credentials the caller asserted were valid came back rejected: the request was
# never sent, so nothing was learned about the operation. Inconclusive.
verdict("authfail", SEL + AUTH_FAIL)
# Same situation, reached by the server hanging up mid-sub-negotiation.
verdict("autheof", SEL + [0x01])
# Authenticated, then the proxy refused the operation itself (0x02 = not
# allowed by ruleset). This is a real observed refusal and must stay REFUSED.
verdict("opdenied", SEL + AUTH_OK + [0x05, 0x02, 0x00, 0x01] + IPV4_TAIL, cmd=0x02)
# Authenticated, then granted. Must stay GRANTED.
verdict("granted", SEL + AUTH_OK + [0x05, 0x00, 0x00, 0x01] + IPV4_TAIL)
# The server offered no acceptable method: a refusal observed before auth.
verdict("nomethod", [0x05, 0xFF])
# Closed during method negotiation: also a refusal the probe saw.
verdict("negeof", [])
# Authenticated, reply head arrived, address tail truncated. A truncated GRANT
# must not be readable as a refusal.
verdict("truncated", SEL + AUTH_OK + [0x05, 0x00, 0x00, 0x01] + [0, 0])

# --- F29: --refusal policy discrimination -----------------------------------
# 0x02 "not allowed by ruleset" is the proxy's own decision. A pass.
verdict("pol_ruleset", SEL + AUTH_OK + [0x05, 0x02, 0x00, 0x01] + IPV4_TAIL,
        refusal="policy")
# 0x01 general server failure is also attributable to the proxy.
verdict("pol_general", SEL + AUTH_OK + [0x05, 0x01, 0x00, 0x01] + IPV4_TAIL,
        refusal="policy")
# 0x03/0x04/0x05 attribute the failure to the DESTINATION. A denied CIDR with
# nothing listening behind it produces these whether or not the deny rule
# exists, so under policy they must read as inconclusive, never as a pass.
verdict("pol_netunreach", SEL + AUTH_OK + [0x05, 0x03, 0x00, 0x01] + IPV4_TAIL,
        refusal="policy")
verdict("pol_hostunreach", SEL + AUTH_OK + [0x05, 0x04, 0x00, 0x01] + IPV4_TAIL,
        refusal="policy")
verdict("pol_connrefused", SEL + AUTH_OK + [0x05, 0x05, 0x00, 0x01] + IPV4_TAIL,
        refusal="policy")
# The same code stays REFUSED under the default, so the narrowing changes
# nothing for run_protocol.sh's operation-rejection cases.
verdict("any_hostunreach", SEL + AUTH_OK + [0x05, 0x04, 0x00, 0x01] + IPV4_TAIL)
# 0x07 "command not supported" is what a BIND/UDP ASSOCIATE rejection looks
# like. It is not an ACL decision, so policy mode calls it inconclusive -- which
# is exactly why those cases must NOT pass --refusal policy.
verdict("pol_cmdunsup", SEL + AUTH_OK + [0x05, 0x07, 0x00, 0x01] + IPV4_TAIL,
        cmd=0x02, refusal="policy")
# A refusal reached before the request was ever sent teaches nothing about the
# destination. Under policy these are inconclusive, so a broken credential or a
# mis-set auth method cannot silently score every ACL check as a pass.
verdict("pol_nomethod", [0x05, 0xFF], refusal="policy")
verdict("pol_negeof", [], refusal="policy")
# A hard close AFTER the request is a refusal in the general operation tests,
# but strict policy requires the explicit 0x02 evidence and calls it inconclusive.
verdict("pol_eof", SEL + AUTH_OK, refusal="policy")
# A grant is a grant either way.
verdict("pol_granted", SEL + AUTH_OK + [0x05, 0x00, 0x00, 0x01] + IPV4_TAIL,
        refusal="policy")


# --- F30: socks5-badauth, the wrong-password oracle -------------------------
# The pinned engine acknowledges RFC 1929 before its strongauth callback runs.
# The request reply, not the sub-negotiation reply, is therefore authoritative;
# the scripts below include a CONNECT request.
def bad_verdict(name, script):
    probe.connect = lambda host, port: FakeSock(script)
    try:
        rc = probe.mode_socks5_badauth("h", 1080, "user", "wrongpass",
                                        "example.com", 80)
    except SystemExit as exc:
        rc = exc.code
    print("%s=%s" % (name, rc))


# Pinned 3proxy acknowledges the RFC 1929 sub-negotiation before its strongauth
# callback runs. The request reply is the authoritative wrong-password oracle:
# 0x02 means the ruleset/auth callback rejected the request, while 0x00 means
# the supposedly-wrong credentials reached a granted CONNECT.
bad_verdict("ba_rejected", SEL + AUTH_OK +
            [0x05, 0x02, 0x00, 0x01] + IPV4_TAIL)
bad_verdict("ba_accepted", SEL + AUTH_OK +
            [0x05, 0x00, 0x00, 0x01] + IPV4_TAIL)
# A generic server failure is not proof that the password was wrong.
bad_verdict("ba_general", SEL + AUTH_OK +
            [0x05, 0x01, 0x00, 0x01] + IPV4_TAIL)
# No access granted by any route still means the wrong password did not work.
bad_verdict("ba_nomethod", [0x05, 0xFF])
bad_verdict("ba_negeof", [])
bad_verdict("ba_autheof", SEL + [0x01])
# The server picked a method we did not offer: something other than the
# credential check answered, so nothing was learned. Inconclusive.
bad_verdict("ba_wrongmethod", [0x05, 0x00])
PYEOF
)
assert_contains "an auth failure is ERROR: the operation was never reached" \
    "authfail=$p_error" "$verdicts"
assert_contains "so is a hangup during authentication" \
    "autheof=$p_error" "$verdicts"
assert_contains "an operation the proxy denied is still REFUSED" \
    "opdenied=$p_refused" "$verdicts"
assert_contains "a grant is still GRANTED" \
    "granted=$p_granted" "$verdicts"
assert_contains "'no acceptable method' is still REFUSED" \
    "nomethod=$p_refused" "$verdicts"
assert_contains "a close during negotiation is still REFUSED" \
    "negeof=$p_refused" "$verdicts"
assert_contains "a truncated grant is ERROR, never REFUSED" \
    "truncated=$p_error" "$verdicts"

# --------------------------------------------------------------------- F29
# The destination-ACL checks in acl_resolution.sh accepted any non-zero reply
# code as proof the deny rule fired. Two of their six targets (10.0.0.1 and
# 192.168.0.1) had no listener, so the proxy answered 0x04/0x05 -- "the
# destination did not answer" -- and those checks passed identically against an
# empty ruleset. --refusal policy is the discrimination; these are its oracle.
assert_contains "0x02 not-allowed-by-ruleset is a policy refusal" \
    "pol_ruleset=$p_refused" "$verdicts"
assert_contains "0x01 general server failure is NOT proof the ruleset fired" \
    "pol_general=$p_error" "$verdicts"
assert_contains "0x03 network unreachable is NOT proof the ruleset fired" \
    "pol_netunreach=$p_error" "$verdicts"
assert_contains "nor is 0x04 host unreachable" \
    "pol_hostunreach=$p_error" "$verdicts"
assert_contains "nor is 0x05 connection refused" \
    "pol_connrefused=$p_error" "$verdicts"
assert_contains "and the default mode is unchanged by the narrowing" \
    "any_hostunreach=$p_refused" "$verdicts"
assert_contains "0x07 command-not-supported is not an ACL decision either" \
    "pol_cmdunsup=$p_error" "$verdicts"
assert_contains "a pre-request auth refusal proves nothing about the destination" \
    "pol_nomethod=$p_error" "$verdicts"
assert_contains "nor does a close during negotiation" \
    "pol_negeof=$p_error" "$verdicts"
assert_contains "a close after the request is inconclusive without REP 0x02" \
    "pol_eof=$p_error" "$verdicts"
assert_contains "and a grant is still GRANTED under policy" \
    "pol_granted=$p_granted" "$verdicts"

# --------------------------------------------------------------------- F30
# Case 2 -- "a wrong password must be refused" -- had no oracle but curl's exit
# status, and scored ANY non-zero status as a pass. A proxy that was down, a DNS
# failure, or a curl built without SOCKS5 support all read as "the wrong password
# was refused", so the one case that proves authentication is enforced was the
# easiest in the file to pass without the proxy doing anything.
assert_contains "a rejected wrong password is REFUSED: the case passes" \
    "ba_rejected=$p_refused" "$verdicts"
assert_contains "an ACCEPTED wrong password is GRANTED, so the case fails" \
    "ba_accepted=$p_granted" "$verdicts"
assert_contains "a generic server failure is inconclusive, not an auth verdict" \
    "ba_general=$p_error" "$verdicts"
assert_contains "no acceptable method still means the wrong password failed" \
    "ba_nomethod=$p_refused" "$verdicts"
assert_contains "so does a close during negotiation, but it is inconclusive" \
    "ba_negeof=$p_error" "$verdicts"
assert_contains "and a close during the credential exchange is inconclusive" \
    "ba_autheof=$p_error" "$verdicts"
assert_contains "an unoffered auth method is inconclusive, not a pass" \
    "ba_wrongmethod=$p_error" "$verdicts"
# The whole point is that the two outcomes are distinguishable. If accept and
# reject ever produced the same code the case would be unfalsifiable.
if [ "$p_refused" != "$p_granted" ]; then
    t_ok
else
    t_bad "REFUSED and GRANTED must be different exit codes"
fi

# The capability has to be used, and used only where it belongs. Checked on code
# lines: both files explain --refusal policy in a comment, so a fixed-string
# search over the whole file is satisfied by the prose and survives deleting the
# invocation itself.
code_has "the ACL script demands a policy-attributable refusal" \
    "$R/tests/protocol/acl_resolution.sh" '--target-port 80 --refusal policy'
code_lacks "the operation-rejection driver does not (0x07 would go inconclusive)" \
    "$R/tests/protocol/run_protocol.sh" '--refusal policy'
# An unknown value must be rejected rather than falling back to the permissive
# default, or a typo silently restores the conflation.
code_has "an unrecognised --refusal value is rejected" \
    "$PROBE" "--refusal must be 'any' or 'policy'"
# Every target the ACL script probes needs a listener AND a direct-reachability
# gate; otherwise "refused" is unfalsifiable regardless of the reply code. The
# gate is anchored on its own curl line, not on the `for a in $LISTEN_ADDRS`
# header, because the listener-spawn loop shares that header and would keep the
# guard satisfied after the gate itself was deleted.
code_has "the ACL script binds a listener for the private-range targets" \
    "$R/tests/protocol/acl_resolution.sh" "ADD_ADDRS='169.254.169.254 10.0.0.1 192.168.0.1'"
code_has "and gates every literal target on direct reachability" \
    "$R/tests/protocol/acl_resolution.sh" '"http://$a/"'
code_has "and every hostname target too" \
    "$R/tests/protocol/acl_resolution.sh" '"http://$h/"'
code_lacks "no target is left with an unguarded listener" \
    "$R/tests/protocol/acl_resolution.sh" 'dummy2_pid'

# F30: the wrong-password case must use the probe as its authority and must
# classify curl by exit code, not by "any non-zero". Anchored on code lines for
# the same reason as the block above.
RP="$R/tests/protocol/run_protocol.sh"
code_has "the wrong-password case has an on-the-wire oracle" \
    "$RP" 'probe socks5-badauth wrong-creds'
code_has "an accepted wrong password fails the run" \
    "$RP" 'bad "2b probe: SOCKS5 ACCEPTED a wrong password and granted CONNECT"'
code_has "and an inconclusive probe result fails too" \
    "$RP" 'bad "2b probe: inconclusive'
code_has "curl recognizes current CURLE_PROXY rejection" \
    "$RP" '[ "$rc2" -eq "$S5_CURL_PROXY_ERR" ]'
code_has "curl recognizes the legacy status only with protocol text" \
    "$RP" '[ "$rc2" -eq "$S5_CURL_LEGACY_PROXY_ERR" ]'
code_has "legacy curl classification pins the SOCKS5 rejection signature" \
    "$RP" 'S5_CURL_LEGACY_AUTH_TEXT'
code_has "and an unrelated curl failure is marked indicative only" \
    "$RP" '2b is authoritative'
# The deliberately-wrong password must be proven different from the real one:
# were they equal, case 2 would be exercising the CORRECT password.
code_has "the wrong password is compared against the configured one" \
    "$RP" '[ "$S5_WRONG_PASS" = "$_ppass" ]'
code_has "and a collision aborts rather than testing nothing" \
    "$RP" 'cannot test anything'
# The mode must exist in the probe and read its credentials from stdin.
code_has "the probe implements the mode" "$PROBE" 'def mode_socks5_badauth'
code_has "and dispatches to it" "$PROBE" 'if mode == "socks5-badauth":'
code_has "and reads its credentials from stdin, never argv" \
    "$PROBE" '"socks5-badauth", "socks4-connect", "socks4a-connect"):'

# F31: an inconclusive curl attempt must not be SCORED as a pass. Cases 2a, 4a
# and 5a all reach an `else` branch when curl fails for a reason not attributable
# to the proxy -- a dead proxy, a DNS failure, a curl without SOCKS4/SOCKS5
# support. Each printed "ok" and incremented the pass counter, so the summary
# line claimed more than the run had proved. They now report through note(),
# which counts separately. The run's verdict is unaffected: the matching probe
# case is authoritative and fails on its own inconclusive result.
code_has "there is a third outcome for an unattributable curl failure" \
    "$RP" 'note() {'
code_has "and it counts separately from passes" \
    "$RP" 'inconclusive=$((inconclusive + 1))'
code_lacks "note() must not increment the pass counter" \
    "$RP" 'inconclusive=$((pass + 1))'
code_has "and the summary reports the count rather than hiding it" \
    "$RP" 'inconclusive (not counted as passes)'
# The invariant, computed rather than spelled out: no line that admits it is
# only indicative may be reported as a pass. This catches a NEW case added with
# the old shape, which a fixed-string check on 2a/4a/5a would miss.
okindic=$(grep -v '^[[:space:]]*#' "$RP" | grep -n 'ok "' | grep -c 'indicative' || true)
assert_eq "no case scores an 'indicative only' result as a pass" 0 "$okindic"
noteindic=$(grep -v '^[[:space:]]*#' "$RP" | grep -c 'note ".*indicative' || true)
if [ "$noteindic" -eq 3 ]; then
    t_ok
else
    t_bad "expected 3 indicative-only curl results reported via note(), found $noteindic"
fi

# ==========================================================================
# F24: read_until must return when its timeout expires, even though the fd
# never becomes readable and never reaches EOF.
#
# signal.alarm is the vacuity guard: without it a regression here hangs the
# suite instead of failing it, which is precisely the failure mode being fixed.
# ==========================================================================
timing=$(python3 - "$R" 2>&1 <<'PYEOF'
import os, signal, sys, time

sys.path.insert(0, os.path.join(sys.argv[1], "tests/pty"))
import interrupt

# A pipe whose write end stays open in this process: never readable, never EOF.
rfd, wfd = os.pipe()
signal.alarm(8)
start = time.time()
buf, matched = interrupt.read_until(rfd, r"a-prompt-that-never-arrives", timeout=1.0)
elapsed = time.time() - start
signal.alarm(0)
os.close(rfd)
os.close(wfd)
print("returned=yes")
print("matched=%s" % matched)
print("sawnothing=%s" % ("yes" if buf == b"" else "no"))
print("honoured=%s" % ("yes" if elapsed < 5.0 else "no"))
PYEOF
)
tstatus=$?
assert_eq "read_until returns instead of blocking until the job timeout" 0 "$tstatus"
assert_contains "it comes back" "returned=yes" "$timing"
assert_contains "an absent pattern is reported as not matched" "matched=False" "$timing"
assert_contains "with nothing read" "sawnothing=yes" "$timing"
assert_contains "and the timeout it was given is honoured" "honoured=yes" "$timing"

# The bound has to come from select, not from a sleep-and-hope loop: os.read on
# a pty master blocks, so a deadline checked only between reads is unreachable.
src_has "the wait is bounded by select" "$ITR" "select.select"

# The same class of hang exists on the reaping side: a child that ignores SIGINT
# -- the regression interrupt.py exists to catch -- would make a bare waitpid
# block forever and hide the result behind an infrastructure failure.
src_has "the child is reaped without blocking indefinitely" "$ITR" "os.WNOHANG"
src_has "and the wait escalates rather than hanging" "$ITR" "SIGKILL"
src_lacks "no bare blocking waitpid remains at the interrupt site" \
    "$ITR" "status = os.waitpid(pid, 0)"

# ==========================================================================
# Both protocol drivers score an explicit refusal as a pass, so a setup mistake
# that makes every request fail for an unrelated reason would turn their whole
# rejection half green. An empty PASSFILE is exactly that mistake: the proxy
# rejects the credential, not the operation.
#
# run_protocol.sh always guarded this; acl_resolution.sh did not, so its six
# destination-deny checks would each have been recorded as "the deny held" with
# no password ever sent. Both drivers reach the guard before any socket work, so
# running them for real here touches nothing on the network.
# ==========================================================================
emptypass=$(mktemp)
chmod 0600 "$emptypass"
trap 'rm -f "$emptypass"' EXIT HUP INT TERM
for drv in run_protocol acl_resolution; do
    drvout=$(PORT=41080 PROXY_USER=ciuser PASSFILE="$emptypass" S5_ISOLATED=0 \
        sh "$R/tests/protocol/$drv.sh" 2>&1; printf '|%s' "$?")
    assert_eq "$drv.sh reports an empty PASSFILE as inconclusive, not as a pass" \
        2 "${drvout##*|}"
    assert_contains "$drv.sh names the file it refused to use" \
        "PASSFILE is empty" "$drvout"
    assert_not_contains "$drv.sh scores nothing before stopping" "ok   " "$drvout"

    # The exit code alone cannot say WHICH guard fired -- acl_resolution.sh's
    # isolation refusal also exits 2 -- so the message above carries that proof,
    # and the line order below carries the rest: under CI the isolation guard
    # passes, and the empty file must still be caught before any scoring starts.
    pf_line=$(grep -n 'PASSFILE is empty' "$R/tests/protocol/$drv.sh" | head -n 1 | cut -d: -f1)
    body_line=$(grep -n '^pass=0' "$R/tests/protocol/$drv.sh" | head -n 1 | cut -d: -f1)
    if [ -n "$pf_line" ] && [ -n "$body_line" ] && [ "$pf_line" -lt "$body_line" ]; then
        t_ok
    else
        t_bad "$drv.sh must reject an empty PASSFILE before it starts scoring (guard at [$pf_line], scoring at [$body_line])"
    fi
done
rm -f "$emptypass"
trap - EXIT HUP INT TERM

# ==========================================================================
# F25: an absence assertion is only as good as its detector.
#
# t_assert_never_called greps a transcript that only stubbed commands write to.
# For an unstubbed command the transcript is silent, the assertion passes, and
# the invocation goes to the real binary -- so the guard against a prohibited
# command was also what allowed it. Verified here by driving the detector both
# ways: every forbidden command must be stubbed, must record when invoked, and
# t_assert_never_called must actually fail on that record.
# ==========================================================================
. "${S5_REPO_ROOT}/tests/lib/stub.sh"
t_mktestroot
t_stub_init

assert_ne "the harness names the commands that must never be invoked" \
    "" "$T_FORBIDDEN_CMDS"
for fc in $T_FORBIDDEN_CMDS; do
    # A PATH stub, for child processes. Not sufficient on its own -- see F26.
    if [ -x "$S5_TEST_ROOT/bin/$fc" ]; then t_ok; else
        t_bad "$fc has no PATH stub, so a child process would reach the real one"
    fi
    # What actually matters: invoking it is intercepted and recorded. Asserted
    # behaviourally rather than by inspecting `command -v`, because the answer
    # there differs per shell (a path, a bare applet name, or a function name)
    # while the property under test does not.
    "$fc" --probe >/dev/null 2>&1 && fcs=0 || fcs=$?
    assert_ne "$fc does not report success when invoked" 0 "$fcs"
    # A real passwd/su/sudo would not write to our transcript, so a record here
    # is proof the invocation never left the harness.
    assert_contains "invoking $fc is intercepted and recorded" "$fc --probe" "$(t_transcript)"
done

# F26 specifically: the names busybox implements as applets are the ones a PATH
# stub cannot cover, and they are the security-relevant ones. Checked against
# busybox's own applet list where available, so this tracks the build in use
# rather than a hardcoded guess.
if command -v busybox >/dev/null 2>&1; then
    for fc in $T_FORBIDDEN_CMDS; do
        if busybox --list 2>/dev/null | grep -qx -- "$fc"; then
            : >"$T_TRANSCRIPT"
            "$fc" --applet-probe >/dev/null 2>&1
            assert_contains "$fc is intercepted even though busybox has it as an applet" \
                "$fc --applet-probe" "$(t_transcript)"
        fi
    done
else
    t_skip "applet interception" "busybox is not installed"
fi

# And the harness refuses to proceed when interception is broken, rather than
# running a file whose absence assertions cannot fail. Exercised in a child shell
# by adding a name that has no shadow and no stub: t_forbidden_check must abort.
# Done with an invented name rather than by removing a real shadow, so that the
# failure path is proven without ever invoking a real passwd or su.
chk=$(sh -c '
    . "'"$R"'/tests/lib/assert.sh"
    . "'"$R"'/tests/lib/stub.sh"
    t_mktestroot
    t_stub_init
    T_FORBIDDEN_CMDS="nosuchforbidden-xyz"
    t_forbidden_check
    echo REACHED-THE-BODY' 2>&1; printf '|%s' "$?")
assert_ne "the harness aborts when a forbidden command is not intercepted" \
    0 "${chk##*|}"
assert_not_contains "and does not run the file body" "REACHED-THE-BODY" "$chk"
assert_contains "and says which command it could not see" \
    "nosuchforbidden-xyz is not intercepted" "$chk"

# The self-check leaves no residue of its own probing behind, or the first
# t_assert_never_called in a real test file would trip over it.
: >"$T_TRANSCRIPT"
sudo --probe >/dev/null 2>&1 || true
assert_not_contains "the init self-check leaves nothing in the transcript" \
    "t-stub-init-selfcheck" "$(t_transcript)"

# The detector now fires: t_assert_never_called must FAIL on what was just
# recorded. Its verdict is read through the counters rather than its return
# value, which is always 0. Its stderr is diverted to a file for two reasons:
# the expected "not ok" line would otherwise appear in a green run and read as a
# real failure, and the message itself is worth asserting on -- a diagnosis that
# does not name the offending command is not much use in a CI log.
_before=$S5T_FAIL
t_assert_never_called "deliberate: sudo was in fact called" 'sudo --probe' \
    2>"$S5_TEST_ROOT/detector.err"
if [ "$S5T_FAIL" -gt "$_before" ]; then
    S5T_FAIL=$_before          # that failure was the expected outcome
    t_ok
else
    t_bad "t_assert_never_called did not fail on a command that WAS called"
fi
assert_contains "and says what it found" "sudo --probe" "$(cat "$S5_TEST_ROOT/detector.err")"

# ...and it still passes for something genuinely absent, so the check above is
# not simply broken in the failing direction.
_before=$S5T_FAIL
t_assert_never_called "a command that really was not called" 'nosuchcommand-xyz'
if [ "$S5T_FAIL" -eq "$_before" ]; then t_ok; else
    t_bad "t_assert_never_called failed on a command that was never called"
fi

# ==========================================================================
# F27 (HIGH)  The detector's own PATTERN, not just its recording mechanism.
#
# F25/F26 proved the transcript records a forbidden invocation and that
# t_assert_never_called fails on that record. Both self-checks pass an argument
# (`--probe`, `--t-stub-init-selfcheck`), so the *zero-argument* record shape was
# never exercised -- and three shipped guards used '^passwd \|^chpasswd ', whose
# trailing space means "at least one argument". `printf 'user:pass' | chpasswd`,
# credentials on stdin with an empty argv, is the canonical non-interactive
# password set and records the bare line "chpasswd". The guard against the most
# likely form of the prohibited operation could not see it, on GNU grep, today.
# Both directions are proven below, on the helper that replaced those patterns.
# ==========================================================================
: >"$T_TRANSCRIPT"
# The stub must see the exact zero-argument shape, so its $1 must stay empty.
# shellcheck disable=SC2119
printf 'svcuser:secret\n' | chpasswd >/dev/null 2>&1
assert_eq "a zero-argument forbidden call records a bare line" \
    "chpasswd" "$(t_transcript)"

_before=$S5T_FAIL
t_assert_cmd_never_called "deliberate: bare chpasswd was in fact called" chpasswd \
    2>"$S5_TEST_ROOT/detector2.err"
if [ "$S5T_FAIL" -gt "$_before" ]; then
    S5T_FAIL=$_before          # the expected outcome
    t_ok
else
    t_bad "t_assert_cmd_never_called did not fail on a zero-argument invocation"
fi
assert_contains "and names the command it found" "chpasswd" \
    "$(cat "$S5_TEST_ROOT/detector2.err")"

# The retired hand-written pattern, kept as the counter-example that justifies
# the helper: against the same transcript it must NOT match. If this ever starts
# matching, the blind spot closed above was misdiagnosed and this file should say
# so loudly rather than quietly agreeing.
if t_transcript | grep -q -- '^passwd \|^chpasswd '; then
    t_bad "the trailing-space pattern matched a bare invocation: F27 is misdiagnosed"
else
    t_ok
fi

# The helper must also still catch the with-arguments form, or it has merely
# traded one blind spot for another.
: >"$T_TRANSCRIPT"
passwd -l socks5proxy >/dev/null 2>&1
_before=$S5T_FAIL
t_assert_cmd_never_called "deliberate: passwd with arguments was called" passwd \
    2>"$S5_TEST_ROOT/detector3.err"
if [ "$S5T_FAIL" -gt "$_before" ]; then
    S5T_FAIL=$_before
    t_ok
else
    t_bad "t_assert_cmd_never_called missed an invocation that had arguments"
fi

# ...and passes when the commands genuinely were not called.
: >"$T_TRANSCRIPT"
_before=$S5T_FAIL
t_assert_cmd_never_called "forbidden commands that really were not called" \
    passwd chpasswd sudo doas su
if [ "$S5T_FAIL" -eq "$_before" ]; then t_ok; else
    t_bad "t_assert_cmd_never_called failed on commands that were never called"
fi

# Structural, so this cannot regress by someone hand-writing a pattern again.
# `\|` is a GNU BRE extension: under a conforming grep it matches nothing, and a
# pattern that cannot match is an ABSENCE assertion that cannot fail -- the same
# fail-open shape the project fixed inside socks5.sh as F17. test_skeleton.sh's
# ban greps the shipped artifact only, so it never reached the detectors.
bre_abs=$(grep -rnE '^[[:space:]]*t_assert_never_called' "$R/tests/unit" | grep -cF -- '\|' || true)
assert_eq "no absence assertion depends on GNU BRE alternation" 0 "$bre_abs"

# The widest instance of the same bug was not an absence assertion at all: the
# loop checking the rendered config against all 20 SPEC section 6 forbidden
# directives used "^$d\([[:space:]]\|\$\)" and went silent wholesale.
src_has "the forbidden-directive loop matches a bare directive line too" \
    "$R/tests/unit/test_render.sh" 'grep -qxF "$d"'
src_lacks "and no longer depends on BRE alternation" \
    "$R/tests/unit/test_render.sh" '\([[:space:]]\|\$\)'

# ==========================================================================
# F35 (HIGH)  An accepted no-auth method is a security failure in itself.
#
# RFC 1928 section 3: method 0x00 is "NO AUTHENTICATION REQUIRED". Once the
# server selects it, the -u2/auth strong contract is already broken; whatever
# the proxy answers for the CONNECT afterwards (a destination failure 0x03-0x06,
# a close, anything non-grant) says nothing about authentication. mode_socks5_noauth
# scored ALL of those as a correct rejection, so an unauthenticated proxy with a
# dead target passed case 3. The selection of 0x00 must itself be the failure.
# ==========================================================================
probe2=$(python3 - "$PROBE" 2>&1 <<'PYEOF'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("probe_na", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FakeSock:
    def __init__(self, script):
        self.buf = bytes(script)
        self.sent = b""

    def sendall(self, data):
        self.sent += data

    def recv(self, n):
        chunk, self.buf = self.buf[:n], self.buf[n:]
        return chunk

    def close(self):
        pass


def na(name, script):
    probe.connect = lambda host, port: FakeSock(script)
    try:
        rc = probe.mode_socks5_noauth("h", 1080, "example.com", 80)
    except SystemExit as exc:
        rc = exc.code
    print("%s=%s" % (name, rc))


# The bug: no-auth selected, then a destination failure. Must be GRANTED-
# class (0), i.e. a detected security failure, never REFUSED.
na("na_destfail", [0x05, 0x00, 0x05, 0x04, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
# Same for a close right after the method selection.
na("na_closed", [0x05, 0x00])
# And a generic server failure after no-auth acceptance.
na("na_generalfail", [0x05, 0x00, 0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
# Still refuses correctly when the method is rejected at negotiation.
na("na_negrefused", [0x05, 0xFF])
PYEOF
)
assert_eq "an accepted no-auth method followed by a destination failure is a SECURITY failure" \
    "$p_granted" "$(printf '%s\n' "$probe2" | sed -n 's/^na_destfail=//p')"
assert_eq "an accepted no-auth method followed by a close is a SECURITY failure" \
    "$p_granted" "$(printf '%s\n' "$probe2" | sed -n 's/^na_closed=//p')"
assert_eq "an accepted no-auth method followed by a generic failure is a SECURITY failure" \
    "$p_granted" "$(printf '%s\n' "$probe2" | sed -n 's/^na_generalfail=//p')"
assert_eq "a refused method negotiation is still a correct rejection" \
    "$p_refused" "$(printf '%s\n' "$probe2" | sed -n 's/^na_negrefused=//p')"

# The driver must treat the probe's verdict accordingly: a 0 exit for case 3
# is now a hard failure, not a pass.
code_has "the no-auth case treats a GRANTED verdict as a security failure" \
    "$RP" 'bad "3 probe: SOCKS5 granted an unauthenticated CONNECT"'

# ==========================================================================
# F36 (HIGH)  socks5_request always sent ATYP=0x03 (domain), so acl_resolution's
# four "by literal IP" checks never exercised the IPv4 ATYP=0x01 path a wire
# regression could break. A dotted-quad target must be sent as ATYP=0x01 with
# four address octets; names keep ATYP=0x03.
# ==========================================================================
probe3=$(python3 - "$PROBE" 2>&1 <<'PYEOF'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("probe_at", sys.argv[1])
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FakeSock:
    def __init__(self, script):
        self.buf = bytes(script)
        self.sent = b""

    def sendall(self, data):
        self.sent += data

    def recv(self, n):
        chunk, self.buf = self.buf[:n], self.buf[n:]
        return chunk

    def close(self):
        pass


TAIL = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]

for name, target in [("at_ipv4", "10.0.0.1"), ("at_name", "example.invalid")]:
    f = FakeSock(TAIL)
    probe.connect = lambda h, p, f=f: f
    probe.socks5_request(f, 0x01, target, 80)
    print("%s=%s" % (name, f.sent.hex()))
PYEOF
)
at4=$(printf '%s\n' "$probe3" | sed -n 's/^at_ipv4=//p')
atn=$(printf '%s\n' "$probe3" | sed -n 's/^at_name=//p')
# VER CMD RSV ATYP then 0a 00 00 01 (10.0.0.1) and port 0050.
assert_eq "a dotted-quad target is sent as ATYP=0x01 with four octets" \
    "050100010a0000010050" "$at4"
assert_eq "a hostname target keeps ATYP=0x03" "050100030f" "$(printf '%s' "$atn" | cut -c1-10)"
assert_eq "and its domain payload is the encoded name" \
    "6578616d706c652e696e76616c6964" "$(printf '%s' "$atn" | cut -c11-40)"

# The ACL driver's literal-IP cases must ride the new path: assert the probe
# is invoked for those checks with numeric targets (structural anchor only;
# the wire shape above is the real oracle).
code_has "the ACL script still runs the four literal-IP checks" \
    "$R/tests/protocol/acl_resolution.sh" 'by literal IP'

# ==========================================================================
# F37 (MED)  The SOCKS4/4a probes hard-coded user ID "probe" while the ACL user
# is $PROXY_USER (ciuser under CI). A SOCKS4-allowing regression scoped to the
# configured user would still be rejected as unknown-user and reported as
# "SOCKS4 correctly rejected". The probes must send the configured user ID.
# ==========================================================================
code_lacks "mode_socks4 no longer hard-codes the user id" "$PROBE" 'b"probe\\x00"'
code_has "socks4 modes read the configured user from stdin" "$PROBE" \
    '"socks4-connect", "socks4a-connect"'
code_has "the driver passes the configured credentials to socks4 probes" "$RP" \
    'probe socks4-connect with-creds'

t_summary
