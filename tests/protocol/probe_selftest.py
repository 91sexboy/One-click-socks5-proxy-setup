#!/usr/bin/env python3
"""Self-tests for negative probes and unsolicited duplex traffic validation.

Exact reads distinguish split acceptances from refusals; bounded reads distinguish
silence from either outcome. The scripted duplex peer independently generates
valid or corrupted S frames while continuing to echo C frames, so corruption or
stalled unsolicited traffic cannot hide behind successful client round trips.
"""

import contextlib
import io
import os
import select
import socket
import struct
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xray_mixed  # noqa: E402
from selftest_support import TapTestCase, run_tests

GAP = 0.15


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


def scripted_exchange(fault=None, count=24, spacing=0.2, idle=False):
    """Drive real exchange() with an independent, timed wire-protocol fixture.

    The fixture neither imports the target's frame builder nor uses the probe's
    expected payload generator. It continues echoing after its S stream stalls,
    so an echo must never be mistaken for unsolicited progress.
    """
    client, server = socket.socketpair()
    stopped = threading.Event()
    errors = []
    cid, nonce = 4242, b"NONCE-AA"

    def wire(kind, seq, payload, frame_cid=cid, frame_nonce=nonce):
        body = kind + struct.pack("!II", frame_cid, seq) + frame_nonce + payload
        return b"X5" + struct.pack("!I", len(body)) + body

    def serve():
        start = time.monotonic()
        next_server = start
        seq = 0
        buffered = b""
        try:
            while not stopped.is_set():
                now = time.monotonic()
                if now >= next_server:
                    next_server = now + 0.1
                    send = not (fault == "once" and seq > 0)
                    send = send and not (fault == "late-stop" and now - start > 2.4)
                    if send:
                        number = 0 if fault == "duplicate" else seq
                        if fault == "skip":
                            number += 1
                        payload = b"wrong" if fault == "payload" else ("server-%d" % number).encode("ascii")
                        server.sendall(wire(
                            b"S", number, payload,
                            cid + 1 if fault == "identity" else cid,
                            b"WRONG-AA" if fault == "nonce" else nonce,
                        ))
                        seq += 1
                if not select.select([server], [], [], 0.02)[0]:
                    continue
                chunk = server.recv(65536)
                if not chunk:
                    return
                buffered += chunk
                while len(buffered) >= 6:
                    length = struct.unpack("!I", buffered[2:6])[0]
                    if len(buffered) < length + 6:
                        break
                    body, buffered = buffered[6:length + 6], buffered[length + 6:]
                    if body[:1] != b"C":
                        raise ValueError("fixture expected a client frame")
                    server.sendall(b"X5" + struct.pack("!I", len(body)) + b"E" + body[1:])
        except OSError:
            if not stopped.is_set():
                errors.append("fixture socket failed")
        except Exception as exc:
            errors.append(type(exc).__name__)
        finally:
            server.close()

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    problem = None
    try:
        xray_mixed.exchange(client, cid, nonce, count=count, spacing=spacing, idle=idle)
    except (RuntimeError, xray_mixed.ProbeTimeout, xray_mixed.PeerClosed) as exc:
        problem = str(exc)
    finally:
        stopped.set()
        client.close()
        worker.join(2)
    if errors or worker.is_alive():
        raise RuntimeError("scripted exchange fixture did not finish cleanly")
    return problem


def exchange_checks(check, fault=None):
    if fault:
        check("unsolicited %s is rejected" % fault,
              scripted_exchange(fault, count=24 if fault in ("once", "late-stop") else 4) is not None)
        return
    check("correct continuous unsolicited frames pass", scripted_exchange() is None)
    check("unsolicited frames remain valid through idle and resume",
          scripted_exchange(count=4, spacing=0, idle=True) is None)
    for fault in ("payload", "identity", "nonce", "duplicate", "skip", "once", "late-stop"):
        problem = scripted_exchange(fault)
        check("unsolicited %s is rejected" % fault, problem is not None)


def connection_cleanup_checks(check):
    original = xray_mixed.connect
    endpoint = xray_mixed.Endpoint("127.0.0.1", 1)
    for connector in (xray_mixed.socks5_connect, xray_mixed.http_connect):
        client, peer = socket.socketpair()
        peer.close()
        xray_mixed.connect = lambda *args: client
        try:
            try:
                connector(endpoint, endpoint, xray_mixed.Credentials("u", "p"))
            except (OSError, RuntimeError, xray_mixed.PeerClosed):
                pass
            check("%s closes a failed handshake socket" % connector.__name__, client.fileno() == -1)
        finally:
            xray_mixed.connect = original
            client.close()


class HandshakeSocket:
    def __init__(self, replies):
        self.replies = list(replies)
        self.sent = []
        self.closed = False

    def sendall(self, data):
        self.sent.append(data)

    def settimeout(self, timeout):
        pass

    def recv(self, size):
        reply = self.replies.pop(0)
        if isinstance(reply, BaseException):
            raise reply
        if len(reply) > size:
            self.replies.insert(0, reply[size:])
        return reply[:size]

    def close(self):
        self.closed = True


def handshake_checks(check):
    endpoint = xray_mixed.Endpoint("127.0.0.1", 23456)
    creds = xray_mixed.Credentials("u", "p")
    for failure in ("socket-timeout", "expired-deadline"):
        sock = HandshakeSocket([socket.timeout("synthetic stall")])
        observed = None
        clock = [0, 11] if failure == "expired-deadline" else [0, 0, 0]
        with patch.object(xray_mixed, "connect", return_value=sock), \
                patch.object(xray_mixed.time, "monotonic", side_effect=clock):
            try:
                xray_mixed.http_connect(endpoint, endpoint, creds)
            except BaseException as error:
                observed = error
        check("HTTP %s becomes ProbeTimeout" % failure, isinstance(observed, xray_mixed.ProbeTimeout))
        check("HTTP %s closes its socket" % failure, sock.closed)

    for connector, reply, suffix in (
            (xray_mixed.http_connect, b"HTTP/1.1 200 OK\r\n\r\n", b"Connection: keep-alive\r\n\r\n"),
            (xray_mixed.http_wrong_auth, b"HTTP/1.1 407 Required\r\n\r\n", b"\r\n")):
        sock = HandshakeSocket([reply])
        with patch.object(xray_mixed, "connect", return_value=sock):
            connector(endpoint, endpoint, creds)
        expected = (b"CONNECT 127.0.0.1:23456 HTTP/1.1\r\nHost: 127.0.0.1:23456\r\n"
                    b"Proxy-Authorization: Basic dTpw\r\n" + suffix)
        check("%s preserves its exact request bytes" % connector.__name__, sock.sent == [expected])
        sock.close()

    calls = (
        ("positive", lambda: xray_mixed.socks5_connect(endpoint, endpoint, creds)),
        ("wrong-auth", lambda: xray_mixed.socks5_wrong_auth(endpoint, creds)),
        ("command", lambda: xray_mixed.socks5_reject_command(endpoint, endpoint, creds, 2)),
        ("boundary", lambda: xray_mixed.socks5_denied_destination(endpoint, endpoint, creds)),
    )
    for label, call in calls:
        for stage, replies in (("negotiation", [b"\x05", b"\xff"]),
                               ("authentication", [b"\x05", b"\x02", b"\x01", b"\x01"]),
                               ("negotiation-timeout", [socket.timeout()]),
                               ("authentication-timeout", [b"\x05\x02", socket.timeout()])):
            sock = HandshakeSocket(replies)
            with patch.object(xray_mixed, "connect", return_value=sock):
                try:
                    result = call()
                except BaseException as error:
                    result = error
            if stage.endswith("timeout"):
                expected = isinstance(result, xray_mixed.ProbeTimeout)
            elif label == "positive" or (label == "boundary" and stage == "authentication"):
                expected = isinstance(result, RuntimeError)
            else:
                expected = result is True
            check("%s preserves %s rejection policy" % (label, stage), expected)
            check("%s closes after %s" % (label, stage), sock.closed)

    sock = HandshakeSocket([b"\x05", b"\x02", b"\x01", b"\x00",
                            b"\x05\x00\x00\x01" + b"\x00" * 6])
    with patch.object(xray_mixed, "connect", return_value=sock):
        result = xray_mixed.socks5_connect(endpoint, endpoint, creds)
    check("split SOCKS5 acceptance reaches the tunnel", result is sock and not sock.closed)
    check("SOCKS5 sends negotiation, credentials and destination unchanged", sock.sent == [
        b"\x05\x01\x02", b"\x01\x01u\x01p", b"\x05\x01\x00\x01\x7f\x00\x00\x01\x5b\xa0"])
    sock.close()

    slow_send = HandshakeSocket([b"\x05\x02", b"\x01\x00"])
    clock = [0]

    def delayed_send(data):
        slow_send.sent.append(data)
        clock[0] += 6

    slow_send.sendall = delayed_send
    with patch.object(xray_mixed, "connect", return_value=slow_send), \
            patch.object(xray_mixed.time, "monotonic", side_effect=lambda: clock[0]):
        try:
            result = xray_mixed.socks5_wrong_auth(endpoint, creds)
        except xray_mixed.ProbeTimeout:
            result = None
    check("wrong-auth gives each reply five seconds after its request is sent", result is False)

    sockets = [HandshakeSocket([]), HandshakeSocket([])]
    with patch.object(xray_mixed, "socks5_connect", side_effect=sockets), \
            patch.object(xray_mixed, "exchange"), \
            patch.object(xray_mixed.os, "urandom", side_effect=[b"NONCE-AA", b"NONCE-BB"]) as random_bytes:
        xray_mixed.tunnel_once("socks5", endpoint, endpoint, creds, 123)
        xray_mixed.tunnel_once("socks5", endpoint, endpoint, creds, 123)
    check("each tunnel obtains an independent eight-byte nonce", [call.args for call in random_bytes.call_args_list] == [(8,), (8,)])
    check("the generated nonce reaches each hello frame", [sock.sent[0][15:23] for sock in sockets] == [b"NONCE-AA", b"NONCE-BB"])

    with patch.object(sys, "argv", ["probe", "--port", "1", "--target-port", "2", "--passfile", "unused"]), \
            patch.object(xray_mixed, "read_passfile", return_value=("u", "p")), \
            patch.object(xray_mixed, "tunnel_once", side_effect=RuntimeError("synthetic foreground failure")), \
            patch.object(xray_mixed.concurrent.futures, "ThreadPoolExecutor") as executor:
        pool = executor.return_value
        pool.__enter__.return_value = pool
        try:
            xray_mixed.main()
        except RuntimeError:
            pass
        check("foreground failure closes the long-lived executor", pool.__exit__.called)


def rejection_checks(check):
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


class ProbeTests(TapTestCase):
    def test_handshakes(self):
        handshake_checks(self.check)

    def test_connection_cleanup(self):
        connection_cleanup_checks(self.check)

    def test_rejections(self):
        rejection_checks(self.check)

    def test_main_case_order(self):
        events = []
        output = io.StringIO()
        argv = ["probe", "--port", "1", "--target-port", "2", "--passfile", "unused"]
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys, "argv", argv))
            stack.enter_context(patch.object(xray_mixed, "read_passfile", return_value=("u", "p")))
            executor = stack.enter_context(patch.object(xray_mixed.concurrent.futures, "ThreadPoolExecutor"))
            pool = executor.return_value.__enter__.return_value
            pool.submit.side_effect = lambda *args: events.append("longlived-start") or pool.submit.return_value
            pool.submit.return_value.result.side_effect = lambda **kwargs: events.append("longlived-result")
            for name in ("tunnel_once", "direct_control", "socks5_denied_destination", "socks5_wrong_auth",
                         "http_wrong_auth", "socks5_noauth", "socks4_rejected", "socks5_reject_command", "concurrency"):
                stack.enter_context(patch.object(xray_mixed, name,
                                                 side_effect=lambda *args, _name=name, **kwargs: events.append(_name) or True))
            stack.enter_context(patch.object(xray_mixed, "ipv6_target_available", return_value=True))
            stack.enter_context(contextlib.redirect_stdout(output))
            status = xray_mixed.main()
        self.check("main preserves all protocol marker ordering", status == 0 and output.getvalue().splitlines() == [
            "mixed_target_ipv4=ok", "mixed_http_connect=ok", "mixed_target_hostname=ok", "mixed_target_ipv6=ok",
            "mixed_denied_control=ok", "mixed_denied_destination=ok", "mixed_denied_hostname=ok",
            "mixed_concurrency_1=ok", "mixed_concurrency_32=ok", "mixed_concurrency_128=ok",
            "mixed_longlived=ok", "mixed_protocol=ok"])
        self.check("main keeps long-lived overlap and direct controls before refusals", events == [
            "longlived-start", "tunnel_once", "tunnel_once", "tunnel_once", "tunnel_once",
            "direct_control", "direct_control", "socks5_denied_destination", "socks5_denied_destination",
            "socks5_wrong_auth", "http_wrong_auth", "socks5_noauth", "socks4_rejected", "socks4_rejected",
            "socks5_reject_command", "socks5_reject_command", "concurrency", "concurrency", "concurrency",
            "longlived-result"])
        self.check("main joins the long-lived tunnel with its original budget", pool.submit.return_value.result.call_args.kwargs == {"timeout": 60})


class ExchangeTests(TapTestCase):
    fault = None

    def test_unsolicited_exchange(self):
        exchange_checks(self.check, self.fault)


def main():
    loader = unittest.defaultTestLoader
    if sys.argv[1:2] == ["--handshake-only"]:
        suite = unittest.TestSuite([ProbeTests("test_handshakes")])
    elif sys.argv[1:2] == ["--exchange-only"]:
        ExchangeTests.fault = sys.argv[2] if len(sys.argv) > 2 else None
        suite = loader.loadTestsFromTestCase(ExchangeTests)
    else:
        suite = loader.loadTestsFromTestCase(ProbeTests)
    return run_tests(suite)


if __name__ == "__main__":
    sys.exit(main())
