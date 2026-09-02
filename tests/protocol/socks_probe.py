#!/usr/bin/env python3
"""Raw SOCKS protocol probe. TEST-ONLY TOOLING.

This file exists so the CI protocol-acceptance suite can send frames that curl
cannot express: a SOCKS5 handshake offering only "no authentication", a SOCKS5
BIND request, and a SOCKS5 UDP ASSOCIATE request.

It is NOT a runtime dependency of socks5.sh and must never become one.
socks5.sh depends only on POSIX sh, curl, sha256sum and standard base utilities.

Credentials are read from stdin ("user\\npassword\\n") so they never appear in
argv and therefore never in CI logs.

Exit codes (three distinct outcomes, never conflated):
    0  GRANTED  - the proxy replied with a success code
    1  REFUSED  - the proxy explicitly refused, OR closed the connection after
                  the request (a hard refusal). Both are correct rejections.
    2  ERROR    - the probe itself failed: could not connect, a malformed or
                  TRUNCATED reply, or an internal fault. This is inconclusive and never a pass.
                   A reply head that arrives with a truncated address tail
                  is an ERROR, not a refusal: treating it as a refusal would let
                  a truncated GRANT slip through the release gate.
                   Failing to authenticate with credentials the caller supplied
                  as valid is also an ERROR: the request was never reached, so
                  nothing was learned about the operation being tested.

Exit 1 is reserved for a rejection the probe actually observed. Every other
outcome, including an unforeseen exception, must exit 2 -- Python exits 1 on an
uncaught traceback, and the callers read 1 as "correctly rejected", so a crash
would otherwise be scored as a security pass. The __main__ guard at the bottom
enforces that.

The distinction between an explicit refusal, an EOF refusal and a truncated
reply is printed to stderr so a CI log shows which one happened.

--refusal policy narrows what counts as REFUSED (default: any refusal does).
A caller asking "did the *destination ACL* reject this?" cannot accept every
non-zero reply code, because 0x03/0x04/0x05/0x06 are exactly what a proxy
answers when the destination itself is unreachable. A denied CIDR with nothing
listening behind it produces those codes whether or not the deny rule exists,
so the ACL checks in acl_resolution.sh would pass against an empty ruleset.
Under --refusal policy only a proxy-attributable refusal counts; an
unreachable-destination code is ERROR (inconclusive), never a pass.
"""

import socket
import struct
import sys

GRANTED = 0
REFUSED = 1
ERROR = 2

# SOCKS5 reply codes (RFC 1928 section 6) grouped by what they attribute the
# failure to. Only the first group shows the proxy's own policy rejected the
# request; the second says the proxy tried and the destination did not answer.
# Only 0x02 means the proxy's access-control ruleset denied the request. RFC
# 1928 assigns 0x01 to a generic server failure; that is not evidence that the
# destination ACL or strongauth callback made the decision.
POLICY_REPLIES = (0x02,)  # connection not allowed by ruleset
UNREACHABLE_REPLIES = (0x03, 0x04, 0x05, 0x06)  # net/host unreachable, refused, TTL

TIMEOUT = 15.0


def die(msg, code=ERROR):
    sys.stderr.write("probe: %s\n" % msg)
    sys.exit(code)


def read_exactly(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise EOFError("connection closed after %d of %d bytes" % (len(buf), n))
        buf += chunk
    return buf


def connect(host, port):
    sock = socket.create_connection((host, port), timeout=TIMEOUT)
    sock.settimeout(TIMEOUT)
    return sock


def socks5_negotiate(sock, methods):
    """Send a method list; return the single method the server selected."""
    sock.sendall(bytes([0x05, len(methods)]) + bytes(methods))
    reply = read_exactly(sock, 2)
    if reply[0] != 0x05:
        raise ValueError("not a SOCKS5 reply: version byte 0x%02x" % reply[0])
    return reply[1]


def socks5_userpass(sock, user, password):
    """RFC 1929 sub-negotiation. True when the credentials were accepted."""
    ub = user.encode("utf-8")
    pb = password.encode("utf-8")
    sock.sendall(bytes([0x01, len(ub)]) + ub + bytes([len(pb)]) + pb)
    reply = read_exactly(sock, 2)
    return reply[1] == 0x00


class TruncatedReply(Exception):
    """The reply head arrived but its address tail did not.

    This must never be conflated with a refusal: a truncated GRANT would
    otherwise read as a rejection and let a real failure pass the gate.
    """


def _is_dotted_quad(host):
    parts = host.split(".")
    if len(parts) != 4:
        return False
    for p in parts:
        if not p.isdigit() or len(p) > 3 or int(p) > 255:
            return False
        if len(p) > 1 and p[0] == "0":
            return False
    return True


def _is_ipv6_literal(host):
    try:
        socket.inet_pton(socket.AF_INET6, host)
    except OSError:
        return False
    return True


def socks5_request(sock, cmd, host, port):
    """Send a SOCKS5 request; return the reply code.

    A dotted-quad target is sent as ATYP=0x01 with four address octets -- the
    literal-IPv4 path -- while an IPv6 literal is sent as ATYP=0x04 with its
    sixteen packed address bytes. Other targets are sent as ATYP=0x03. The
    literal and hostname paths are different code inside the proxy, so a
    regression affecting only one of them is invisible to a probe that always
    uses the other.

    The ACL checks in acl_resolution.sh rely on the IPv4 distinction: their
    "by literal IP" cases must exercise ATYP=0x01, not merely put digits inside
    a domain string.

    Raises EOFError only if the connection closes before the 4-byte reply head
    (a hard refusal). If the head arrives but the address tail is truncated,
    TruncatedReply is raised instead, so the caller reports an ERROR rather
    than a refusal.
    """
    if _is_dotted_quad(host):
        octets = [int(p) for p in host.split(".")]
        payload = (bytes([0x05, cmd, 0x00, 0x01]) +
                   bytes(octets) + struct.pack("!H", port))
    elif _is_ipv6_literal(host):
        payload = (bytes([0x05, cmd, 0x00, 0x04]) +
                   socket.inet_pton(socket.AF_INET6, host) + struct.pack("!H", port))
    else:
        hb = host.encode("idna")
        payload = bytes([0x05, cmd, 0x00, 0x03, len(hb)]) + hb + struct.pack("!H", port)
    sock.sendall(payload)
    head = read_exactly(sock, 4)
    if head[0] != 0x05:
        raise ValueError("not a SOCKS5 reply")
    atyp = head[3]
    try:
        if atyp == 0x01:
            read_exactly(sock, 4 + 2)
        elif atyp == 0x03:
            ln = read_exactly(sock, 1)[0]
            read_exactly(sock, ln + 2)
        elif atyp == 0x04:
            read_exactly(sock, 16 + 2)
        else:
            raise TruncatedReply("unknown ATYP 0x%02x in the reply" % atyp)
    except EOFError as exc:
        raise TruncatedReply(
            "reply code 0x%02x received but the address tail was truncated: %s"
            % (head[1], exc)
        )
    return head[1]


def mode_socks5(host, port, user, password, target, tport, cmd, refusal="any"):
    """SOCKS5 with RFC 1929 credentials that the caller asserts are valid.

    An authentication failure here is an ERROR, not a REFUSED. Every caller of
    this mode supplies credentials it believes are correct and is asking a
    question about the *operation* (CONNECT, BIND, UDP ASSOCIATE) or about the
    destination ACL. If the handshake stops at authentication, the operation was
    never reached, so "refused" would be a claim the probe cannot support: a
    mistyped PASSFILE would have scored the BIND and UDP ASSOCIATE rejection
    cases, and all six destination-deny cases, as passes.

    refusal="policy" applies the same reasoning one step further, to the reply
    code itself: only a refusal attributable to the proxy counts. See
    POLICY_REPLIES / UNREACHABLE_REPLIES and the module docstring. Under it a
    refusal at method-negotiation time is an ERROR too -- the request was never
    sent, so it says nothing about the destination.
    """
    strict = refusal == "policy"
    sock = connect(host, port)
    try:
        try:
            method = socks5_negotiate(sock, [0x02])
        except EOFError:
            if strict:
                die("closed during method negotiation, so the request was "
                    "never sent and nothing was learned about the destination")
            sys.stderr.write("probe: refused - closed during method negotiation\n")
            return REFUSED
        if method == 0xFF:
            if strict:
                die("no offered auth method was acceptable, so the request was "
                    "never sent and nothing was learned about the destination")
            sys.stderr.write("probe: refused - no acceptable auth method\n")
            return REFUSED
        if method != 0x02:
            die("server selected method 0x%02x, expected 0x02" % method)
        try:
            if not socks5_userpass(sock, user, password):
                die("credentials the caller supplied as valid were rejected, so "
                    "the request itself was never reached")
        except EOFError:
            die("connection closed during authentication with credentials the "
                "caller supplied as valid, so the request was never reached")
        try:
            rep = socks5_request(sock, cmd, target, tport)
        except EOFError:
            # Under the default operation tests, a close after the request is an
            # observed refusal. Under strict destination-policy mode, however,
            # only RFC 1928 REP 0x02 proves the ruleset made that decision.
            if strict:
                die("connection closed after the request without REP 0x02; "
                    "the destination ruleset decision is inconclusive")
            sys.stderr.write("probe: refused - closed after the request (EOF)\n")
            return REFUSED
        except TruncatedReply as exc:
            # The server DID reply; we just could not read all of it. Reporting
            # this as a refusal would let a truncated GRANT pass the gate.
            die("truncated reply: %s" % exc)
        if rep == 0x00:
            return GRANTED
        if strict and rep not in POLICY_REPLIES:
            if rep in UNREACHABLE_REPLIES:
                die("reply code 0x%02x attributes the failure to the "
                    "destination, not to the proxy's ruleset; with a live "
                    "listener behind the target this is inconclusive" % rep)
            die("reply code 0x%02x is not a policy refusal (expected one of "
                "%s), so it does not show the ruleset rejected the request"
                % (rep, " ".join("0x%02x" % c for c in POLICY_REPLIES)))
        sys.stderr.write("probe: refused - reply code 0x%02x\n" % rep)
        return REFUSED
    finally:
        sock.close()


def mode_socks5_badauth(host, port, user, password, target, tport):
    """Prove a wrong password is rejected by the pinned engine.

    3proxy 0.9.9.0 sends the RFC 1929 sub-negotiation success reply before
    calling ``strongauth``. Therefore that reply is deliberately NOT treated as
    credential acceptance here. The probe must send a CONNECT and classify the
    subsequent SOCKS5 reply: REP 0x02 is the proxy's ruleset/auth refusal, while
    REP 0x00 proves that the supposedly-wrong credentials were accepted far
    enough to establish a connection.

    Other replies are ERROR. In particular, a generic server failure or a
    destination failure cannot prove that the password was rejected.
    """
    sock = connect(host, port)
    try:
        try:
            method = socks5_negotiate(sock, [0x02])
        except (EOFError, OSError) as exc:
            die("transport error during method negotiation: %s" % exc)
        if method == 0xFF:
            sys.stderr.write("probe: refused - no acceptable auth method\n")
            return REFUSED
        if method != 0x02:
            die("server selected method 0x%02x, expected 0x02" % method)
        try:
            accepted = socks5_userpass(sock, user, password)
        except (EOFError, OSError) as exc:
            die("transport error during authentication: %s" % exc)
        if not accepted:
            sys.stderr.write("probe: refused - wrong credentials rejected\n")
            return REFUSED

        try:
            rep = socks5_request(sock, 0x01, target, tport)
        except (EOFError, OSError) as exc:
            die("transport error after authentication: %s" % exc)
        except TruncatedReply as exc:
            die("truncated reply: %s" % exc)
        if rep == 0x00:
            sys.stderr.write("probe: GRANTED - a password the caller supplied as "
                             "WRONG established CONNECT\n")
            return GRANTED
        if rep == 0x02:
            sys.stderr.write("probe: refused - proxy ruleset rejected CONNECT\n")
            return REFUSED
        die("reply code 0x%02x does not prove wrong-password rejection" % rep)
    finally:
        sock.close()


def mode_socks5_noauth(host, port, target, tport):
    """Offer ONLY "no authentication". A correctly configured proxy must refuse.

    RFC 1928 section 3: method 0x00 is "NO AUTHENTICATION REQUIRED". If the
    server SELECTS it, unauthenticated access has been accepted -- the -u2 /
    auth strong contract is broken at that moment, and no later reply can say
    otherwise. A destination failure (REP 0x03-0x06) or a close after the
    method selection therefore proves nothing about authentication; scoring
    those as a correct rejection let an unauthenticated proxy with a dead
    target pass the case. Selection of 0x00 is reported as the alarming
    outcome (GRANTED) so the driver records a hard failure.
    """
    sock = connect(host, port)
    try:
        try:
            method = socks5_negotiate(sock, [0x00])
        except EOFError:
            sys.stderr.write("probe: refused - closed during method negotiation\n")
            return REFUSED
        if method != 0x00:
            sys.stderr.write("probe: refused - no-auth method not accepted\n")
            return REFUSED
        sys.stderr.write("probe: SECURITY - the proxy ACCEPTED the "
                         "no-authentication method\n")
        return GRANTED
    finally:
        sock.close()


def mode_socks4(host, port, target, tport, use_4a, user):
    """SOCKS4 / SOCKS4a CONNECT. Both must be refused.

    The user ID is taken from the configured account, not hard-coded: the
    release gate exists to catch an engine regression that allows SOCKS4 for
    the ACL-configured user, and with a stranger's user ID such a regression
    is rejected as unknown-user and misreported as "SOCKS4 correctly
    rejected". SOCKS4 carries no password field, so the password line read
    from stdin is ignored here.
    """
    sock = connect(host, port)
    try:
        if use_4a:
            addr = socket.inet_aton("0.0.0.1")
        else:
            try:
                addr = socket.inet_aton(target)
            except OSError:
                addr = socket.inet_aton(socket.gethostbyname(target))
        ub = user.encode("idna") if user else b""
        req = bytes([0x04, 0x01]) + struct.pack("!H", tport) + addr + ub + b"\x00"
        if use_4a:
            req += target.encode("idna") + b"\x00"
        sock.sendall(req)
        try:
            reply = read_exactly(sock, 8)
        except EOFError:
            sys.stderr.write("probe: refused - closed after the request (EOF)\n")
            return REFUSED
        if reply[1] == 0x5A:
            return GRANTED
        sys.stderr.write("probe: refused - SOCKS4 reply code 0x%02x\n" % reply[1])
        return REFUSED
    finally:
        sock.close()


def main(argv):
    opts = {
        "host": "127.0.0.1",
        "port": None,
        "mode": None,
        "target-host": "example.com",
        "target-port": "80",
        "refusal": "any",
    }
    i = 1
    while i < len(argv):
        key = argv[i]
        if not key.startswith("--"):
            die("unexpected argument: %s" % key)
        name = key[2:]
        if name not in opts:
            die("unknown option: %s" % key)
        if i + 1 >= len(argv):
            die("option %s needs a value" % key)
        opts[name] = argv[i + 1]
        i += 2

    if opts["port"] is None or opts["mode"] is None:
        die("usage: socks_probe.py --port P --mode MODE [--host H] "
            "[--target-host T] [--target-port P] [--refusal any|policy]")

    # An unrecognised value must not silently fall back to "any": that is the
    # permissive setting, so a typo would quietly restore the very conflation
    # --refusal policy exists to prevent.
    if opts["refusal"] not in ("any", "policy"):
        die("--refusal must be 'any' or 'policy', got %r" % opts["refusal"])

    # Ports are parsed and range-checked here, not left to int() and struct.
    # A ValueError from int() escaped as an uncaught traceback, and Python exits
    # 1 on an uncaught exception -- which is this probe's REFUSED code. A typo in
    # a CI port would therefore have been recorded as "the proxy correctly
    # refused" by every rejection case in run_protocol.sh, including the SOCKS4
    # release gate. struct.error from an out-of-range --target-port is not in the
    # except clause below either, so it escaped the same way.
    def port_arg(name):
        raw = opts[name]
        try:
            value = int(raw)
        except ValueError:
            die("--%s must be a decimal integer, got %r" % (name, raw))
        if not 1 <= value <= 65535:
            die("--%s must be between 1 and 65535, got %d" % (name, value))
        return value

    port = port_arg("port")
    tport = port_arg("target-port")
    target = opts["target-host"]
    host = opts["host"]
    mode = opts["mode"]
    refusal = opts["refusal"]

    user = password = ""
    if mode in ("socks5-connect", "socks5-bind", "socks5-udpassoc",
                "socks5-badauth", "socks4-connect", "socks4a-connect"):
        data = sys.stdin.read().split("\n")
        if len(data) < 2:
            die("credentials expected on stdin as user\\npassword")
        user, password = data[0], data[1]

    try:
        if mode == "socks5-connect":
            return mode_socks5(host, port, user, password, target, tport, 0x01,
                               refusal)
        if mode == "socks5-bind":
            return mode_socks5(host, port, user, password, target, tport, 0x02,
                               refusal)
        if mode == "socks5-udpassoc":
            return mode_socks5(host, port, user, password, target, tport, 0x03,
                               refusal)
        if mode == "socks5-badauth":
            return mode_socks5_badauth(host, port, user, password, target, tport)
        if mode == "socks5-noauth":
            return mode_socks5_noauth(host, port, target, tport)
        if mode == "socks4-connect":
            return mode_socks4(host, port, target, tport, False, user)
        if mode == "socks4a-connect":
            return mode_socks4(host, port, target, tport, True, user)
        die("unknown mode: %s" % mode)
    except TruncatedReply as exc:
        die("truncated reply: %s" % exc)
    except (OSError, EOFError, ValueError, UnicodeError, struct.error) as exc:
        die("transport error: %s" % exc)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except BaseException as exc:
        # The last line of defence for the same reason as port_arg above: any
        # unforeseen exception would otherwise exit 1, and 1 means REFUSED,
        # so a crash in the probe would be scored as a security pass.
        sys.stderr.write("probe: internal fault: %s: %s\n"
                         % (type(exc).__name__, exc))
        sys.exit(ERROR)
