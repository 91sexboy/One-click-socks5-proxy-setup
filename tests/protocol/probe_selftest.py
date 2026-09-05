#!/usr/bin/env python3
"""Self-test for the negative probes in xray_mixed.py.

SPEC 6 requires exact reads on monotonic deadlines. A probe that keeps whatever a
single recv returns cannot tell a complete reply from a fragment, so a proxy that
really accepted the connection can look like one that rejected it: the reply
arrives in two segments, the first read comes back short, and the mismatch reads
as a rejection.

Every case serves a scripted reply in two pieces with a fixed gap between them
and requires the probe to report what the server actually did. The split is
forced rather than raced, so each direction is deterministic.
"""

import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xray_mixed  # noqa: E402

GAP = 0.15
FAILURES = []
CHECKS = []


def check(label, ok):
    CHECKS.append(label)
    if ok:
        print("ok - %s" % label)
    else:
        print("not ok - %s" % label)
        FAILURES.append(label)


def serve_split(pieces, hold=False, hold_after=False):
    """Serve one loopback connection, writing pieces with a gap between them.

    With hold=True nothing is written and the socket is kept open, which is how a
    stalled proxy looks: the probe reaches its deadline with no reply and no
    close, and must not record that as a rejection. With hold_after=True the
    pieces are written and then the socket is held open, which is how a proxy
    that granted a tunnel and then carried nothing looks.
    """
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]

    def run():
        try:
            listener.settimeout(15)
            conn, _ = listener.accept()
            try:
                # Draining the request first keeps the client from seeing a reset
                # instead of the scripted reply when this side closes.
                conn.settimeout(5)
                try:
                    conn.recv(4096)
                except OSError:
                    pass
                if hold:
                    time.sleep(10)
                    return
                for index, piece in enumerate(pieces):
                    if index:
                        time.sleep(GAP)
                    conn.sendall(piece)
                if hold_after:
                    time.sleep(10)
                    return
                if pieces:
                    time.sleep(GAP * 2)
                try:
                    conn.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
            finally:
                conn.close()
        except OSError:
            pass
        finally:
            listener.close()

    thread = threading.Thread(target=run)
    thread.daemon = True
    thread.start()
    return port


def not_a_rejection(call):
    """True when the probe declines to claim a rejection it cannot prove.

    Returning False is fine, and so is raising ProbeTimeout. A bare True is wrong
    -- that is the probe reporting a refusal it never observed -- and so is any
    other exception, which would mean the case never reached the behaviour it
    exists to test, so those propagate rather than counting as a pass.
    """
    try:
        return call() is not True
    except xray_mixed.ProbeTimeout:
        return True


def main():
    target = xray_mixed.Endpoint("127.0.0.1", 1)
    creds = xray_mixed.Credentials("u", "p")

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split([b"\x05", b"\x00"]))
    check("a split no-auth acceptance is not read as a rejection",
          xray_mixed.socks5_noauth(proxy) is False)

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split([b"\x05", b"\xff"]))
    check("a split no-auth refusal is read as a rejection",
          xray_mixed.socks5_noauth(proxy) is True)

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split([b"\x00", b"\x5a\x00\x00\x00\x00\x00\x00"]))
    check("a split SOCKS4 grant is not read as a rejection",
          xray_mixed.socks4_rejected(proxy, target, creds, False) is False)

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split([b"\x00", b"\x5b\x00\x00\x00\x00\x00\x00"]))
    check("a split SOCKS4 refusal is read as a rejection",
          xray_mixed.socks4_rejected(proxy, target, creds, False) is True)

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split(
        [b"HTTP/1.1 40", b"7 Proxy Authentication Required\r\n\r\n"]))
    check("a split 407 is read as a rejection",
          xray_mixed.http_wrong_auth(proxy, target, creds) is True)

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split(
        [b"HTTP/1.1 ", b"200 Connection established\r\n\r\n"]))
    check("a split acceptance is not read as a rejection",
          xray_mixed.http_wrong_auth(proxy, target, creds) is False)

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split([]))
    check("a close with no reply is read as a rejection",
          xray_mixed.http_wrong_auth(proxy, target, creds) is True)

    # A stalled proxy is the other way a probe can claim a rejection it never
    # observed: the reply never arrives, the deadline expires, and a probe that
    # treats its own read failure as a refusal passes the case it exists to fail.
    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split([], hold=True))
    check("a stalled no-auth reply is not read as a rejection",
          not_a_rejection(lambda: xray_mixed.socks5_noauth(proxy, timeout=0.5)))

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split([], hold=True))
    check("a stalled SOCKS4 reply is not read as a rejection",
          not_a_rejection(lambda: xray_mixed.socks4_rejected(
              proxy, target, creds, False, timeout=0.5)))

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split([], hold=True))
    check("a stalled HTTP reply is not read as a rejection",
          not_a_rejection(lambda: xray_mixed.http_wrong_auth(
              proxy, target, creds, timeout=0.5)))

    # The boundary probe authenticates correctly and then asks for a destination
    # inside the boundary, so its answer turns on what happens after the CONNECT.
    # A granted tunnel that carries a byte is a bypass; one that carries nothing,
    # and an outright failure reply, are refusals.
    auth = [b"\x05\x02", b"\x01\x00"]
    grant = [b"\x05\x00\x00", b"\x01" + b"\x00" * 6]
    refusal = [b"\x05\x02\x00", b"\x01" + b"\x00" * 6]

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split(auth + grant + [b"Z"]))
    check("a granted tunnel that carries data is not read as a refusal",
          xray_mixed.socks5_denied_destination(proxy, target, creds) is False)

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split(auth + grant))
    check("a granted tunnel closed without data is read as a refusal",
          xray_mixed.socks5_denied_destination(proxy, target, creds) is True)

    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split(auth + refusal))
    check("a nonzero CONNECT reply is read as a refusal",
          xray_mixed.socks5_denied_destination(proxy, target, creds) is True)

    proxy = xray_mixed.Endpoint(
        "127.0.0.1", serve_split(auth + grant, hold_after=True))
    check("a granted tunnel held silent is read as a refusal",
          xray_mixed.socks5_denied_destination(
              proxy, target, creds, timeout=0.5) is True)

    # Before the grant the rule is the same as for every other negative probe:
    # the probe's own deadline is not evidence of anything.
    proxy = xray_mixed.Endpoint("127.0.0.1", serve_split(auth, hold_after=True))
    check("a stalled CONNECT reply is not read as a refusal",
          not_a_rejection(lambda: xray_mixed.socks5_denied_destination(
              proxy, target, creds, timeout=0.5)))

    print("TESTS %d %d" % (len(CHECKS) - len(FAILURES), len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
