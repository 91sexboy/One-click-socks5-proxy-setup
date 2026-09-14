#!/usr/bin/env python3
"""CI-only SOCKS5/HTTP mixed proxy and duplex transport probe."""

import argparse
import base64
import collections
import concurrent.futures
import json
import os
import select
import socket
import struct
import sys
import threading
import time

ERROR = 2
FRAME_MAGIC = b"X5"
FRAME_HELLO = ord("H")
FRAME_CLIENT = ord("C")
FRAME_SERVER = ord("S")
FRAME_ECHO = ord("E")
# The boundary probe's connection id. Kept clear of the data-plane tunnels, which
# use 1-4 and 1000 upwards, so a frame from either is attributable.
BOUNDARY_CID = 176
STATS_LOCK = threading.Lock()
STATS = {"tunnels": 0, "client_frames": 0, "control_tunnels": 0, "control_frames": 0}

# The proxy endpoint, the target endpoint and the account used to travel as six
# positional arguments through every probe, where a transposed pair still reads
# as valid code.
Endpoint = collections.namedtuple("Endpoint", "host port")
Credentials = collections.namedtuple("Credentials", "user password")


def fail(message):
    raise RuntimeError(message)


class ProbeTimeout(Exception):
    """A read did not complete in time, so the outcome was never observed.

    Distinct from a peer refusal: a probe that cannot tell these apart reports a
    rejection it never saw. Deliberately not a RuntimeError, so that an existing
    `except RuntimeError` cannot swallow it back into a pass.
    """


class PeerClosed(Exception):
    """The peer closed before sending the bytes that were expected.

    For a negative probe this is a genuine refusal; for a positive one it is a
    failure. The caller decides, which is why it is separate from ProbeTimeout.
    """


def recv_bounded(sock, want, deadline):
    """Read up to `want` bytes before `deadline`, or say why it did not happen."""
    if time.monotonic() >= deadline:
        raise ProbeTimeout("read deadline expired")
    sock.settimeout(max(0.05, deadline - time.monotonic()))
    try:
        chunk = sock.recv(want)
    except socket.timeout as exc:
        # socket.timeout is an OSError, which every negative probe treats as a
        # refusal, so it has to become a ProbeTimeout here or the distinction
        # this module draws is lost on the commonest path.
        raise ProbeTimeout("read timed out") from exc
    if not chunk:
        raise PeerClosed("connection closed before the expected data arrived")
    return chunk


def read_exact(sock, size, deadline):
    data = bytearray()
    while len(data) < size:
        data.extend(recv_bounded(sock, size - len(data), deadline))
    return bytes(data)


def connect(endpoint, timeout=10.0):
    sock = socket.create_connection((endpoint.host, endpoint.port), timeout=timeout)
    sock.settimeout(timeout)
    return sock


def read_passfile(path):
    st = os.stat(path)
    if st.st_mode & 0o777 != 0o600:
        fail("PASSFILE must have mode 0600")
    with open(path, encoding="ascii") as handle:
        lines = handle.read().splitlines()
    if len(lines) != 2 or not lines[0] or not lines[1]:
        fail("PASSFILE must contain exactly a username and password")
    return lines[0], lines[1]


def wrong_password(password):
    replacement = "A" if password[0] != "A" else "B"
    result = replacement + password[1:]
    if result == password:
        fail("could not derive a distinct wrong password")
    return result


def socks5_target_address(atyp, target_host):
    """Encode one SOCKS5 destination, choosing the ATYP byte deliberately.

    SPEC 6 wants the IPv4-literal, hostname and IPv6 paths recorded separately,
    so the address type is a parameter rather than always ATYP 1.
    """
    if atyp == "ipv4":
        return b"\x01" + socket.inet_aton(target_host)
    if atyp == "hostname":
        host = target_host.encode("ascii")
        if not 1 <= len(host) <= 255:
            fail("hostname target does not fit a SOCKS5 request")
        return b"\x03" + bytes([len(host)]) + host
    if atyp == "ipv6":
        return b"\x04" + socket.inet_pton(socket.AF_INET6, target_host)
    fail("unknown SOCKS5 address type: %s" % atyp)


def http_authority(endpoint):
    if ":" in endpoint.host:
        return "[%s]:%d" % (endpoint.host, endpoint.port)
    return "%s:%d" % (endpoint.host, endpoint.port)


def socks5_negotiate(sock, deadline):
    sock.sendall(b"\x05\x01\x02")
    # A separate reply budget starts after the request, not before a slow send.
    if deadline is None:
        deadline = time.monotonic() + 5
    return read_exact(sock, 2, deadline) == b"\x05\x02"


def socks5_authenticate(sock, creds, deadline):
    user = creds.user.encode("ascii")
    password = creds.password.encode("ascii")
    sock.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
    if deadline is None:
        deadline = time.monotonic() + 5
    return read_exact(sock, 2, deadline) == b"\x01\x00"


def socks5_connect(proxy, target, creds, atyp="ipv4"):
    sock = connect(proxy)
    try:
        deadline = time.monotonic() + 10
        if not socks5_negotiate(sock, deadline):
            fail("SOCKS5 did not select username/password authentication")
        if not socks5_authenticate(sock, creds, deadline):
            fail("SOCKS5 credentials were rejected")
        sock.sendall(b"\x05\x01\x00" + socks5_target_address(atyp, target.host) + struct.pack("!H", target.port))
        head = read_exact(sock, 4, deadline)
        if head[0] != 5 or head[1] != 0:
            fail("SOCKS5 CONNECT was refused")
        if head[3] == 1:
            read_exact(sock, 6, deadline)
        elif head[3] == 3:
            length = read_exact(sock, 1, deadline)[0]
            read_exact(sock, length + 2, deadline)
        elif head[3] == 4:
            read_exact(sock, 18, deadline)
        else:
            fail("SOCKS5 returned an unknown address type")
        return sock
    except BaseException:
        sock.close()
        raise


def http_connect_request(target, creds, *, keep_alive=False):
    token = base64.b64encode((creds.user + ":" + creds.password).encode("ascii")).decode("ascii")
    authority = http_authority(target)
    request = (
        "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n"
        % (authority, authority, token)
    )
    if keep_alive:
        request += "Connection: keep-alive\r\n"
    return (request + "\r\n").encode("ascii")


def http_connect(proxy, target, creds):
    sock = connect(proxy)
    try:
        sock.sendall(http_connect_request(target, creds, keep_alive=True))
        deadline = time.monotonic() + 10
        response = bytearray()
        while b"\r\n\r\n" not in response:
            response.extend(recv_bounded(sock, 4096, deadline))
            if len(response) > 16384:
                fail("HTTP CONNECT response is too large")
        line = bytes(response).split(b"\r\n", 1)[0]
        if not line.startswith(b"HTTP/1.1 200") and not line.startswith(b"HTTP/1.0 200"):
            fail("HTTP CONNECT was not accepted")
        return sock
    except BaseException:
        sock.close()
        raise


def socks5_wrong_auth(proxy, creds):
    sock = connect(proxy)
    try:
        if not socks5_negotiate(sock, None):
            return True
        return not socks5_authenticate(sock, creds, None)
    except (ConnectionError, OSError, PeerClosed):
        return True
    finally:
        sock.close()


def socks5_noauth(proxy, timeout=5):
    sock = connect(proxy)
    try:
        sock.sendall(b"\x05\x01\x00")
        reply = read_exact(sock, 2, time.monotonic() + timeout)
        return reply != b"\x05\x00"
    except (ConnectionError, OSError, PeerClosed):
        return True
    finally:
        sock.close()


def socks5_reject_command(proxy, target, creds, command):
    sock = connect(proxy)
    try:
        deadline = time.monotonic() + 8
        if not socks5_negotiate(sock, deadline):
            return True
        if not socks5_authenticate(sock, creds, deadline):
            return True
        sock.sendall(b"\x05" + bytes([command, 0, 1]) + socket.inet_aton(target.host) + struct.pack("!H", target.port))
        reply = read_exact(sock, 4, deadline)
        return reply[0] != 5 or reply[1] != 0
    except (ConnectionError, OSError, PeerClosed):
        return True
    finally:
        sock.close()


def socks4_rejected(proxy, target, creds, socks4a, timeout=8):
    sock = connect(proxy)
    try:
        addr = socket.inet_aton("0.0.0.1" if socks4a else target.host)
        request = b"\x04\x01" + struct.pack("!H", target.port) + addr + creds.user.encode("ascii") + b"\x00"
        if socks4a:
            request += target.host.encode("ascii") + b"\x00"
        sock.sendall(request)
        reply = read_exact(sock, 8, time.monotonic() + timeout)
        return reply[1] != 0x5A
    except (ConnectionError, OSError, PeerClosed):
        return True
    finally:
        sock.close()


def http_wrong_auth(proxy, target, creds, timeout=8):
    sock = connect(proxy)
    try:
        deadline = time.monotonic() + timeout
        sock.sendall(http_connect_request(target, creds))
        response = bytearray()
        while b"\r\n" not in response:
            response.extend(recv_bounded(sock, 4096, deadline))
            if len(response) > 8192:
                fail("HTTP status line is too large")
        status = bytes(response).split(b"\r\n", 1)[0].split(b" ")
        return len(status) > 1 and status[1] == b"407"
    except (ConnectionError, OSError, PeerClosed):
        return True
    finally:
        sock.close()


def new_nonce():
    return os.urandom(8)


def make_frame(kind, cid, seq, nonce, payload):
    body = bytes([kind]) + struct.pack("!II", cid, seq) + nonce + payload
    return FRAME_MAGIC + struct.pack("!I", len(body)) + body


def read_frame(sock, deadline):
    head = read_exact(sock, 6, deadline)
    if head[:2] != FRAME_MAGIC:
        fail("target sent a malformed frame magic")
    length = struct.unpack("!I", head[2:])[0]
    if length < 17 or length > 1 << 20:
        fail("target sent an invalid frame length")
    body = read_exact(sock, length, deadline)
    return body[0], struct.unpack("!II", body[1:9]), body[9:17], body[17:]


def validate_server_frame(frame, cid, nonce, expected_seq):
    kind, ids, frame_nonce, payload = frame
    if kind != FRAME_SERVER or ids[0] != cid or frame_nonce != nonce:
        fail("unsolicited frame identity mismatch")
    if ids[1] != expected_seq:
        fail("unsolicited frame sequence mismatch")
    # Independent of duplex_target.frame() and its sender: this is the wire
    # contract, not an expected value supplied by the implementation under test.
    if payload != ("server-%d" % expected_seq).encode("ascii"):
        fail("unsolicited frame payload mismatch")


def exchange(sock, cid, nonce, count=4, idle=False, spacing=0.0, server_seq=0):
    # The target emits every 0.25s. Allow eight such intervals for scheduling,
    # but require progress throughout the exchange, including its final window.
    # Read during spacing/idle rather than counting buffered old frames as fresh
    # progress when the client resumes writing.
    progress_window = 2.0
    last_server = time.monotonic()
    first_server_seq = server_seq

    def receive(until, expected_echo=None):
        nonlocal server_seq, last_server
        now = time.monotonic()
        if now - last_server >= progress_window:
            fail("unsolicited server frames stopped progressing")
        if now >= until:
            return False
        ready = select.select([sock], [], [], min(until, last_server + progress_window) - now)[0]
        if not ready:
            if time.monotonic() - last_server >= progress_window:
                fail("unsolicited server frames stopped progressing")
            return False
        frame = read_frame(sock, last_server + progress_window)
        kind, ids, frame_nonce, frame_payload = frame
        if kind == FRAME_SERVER:
            validate_server_frame(frame, cid, nonce, server_seq)
            server_seq += 1
            last_server = time.monotonic()
        elif kind == FRAME_ECHO:
            if expected_echo is None or ids != (cid, expected_echo[0]) or frame_nonce != nonce:
                fail("target echo identity or sequence mismatch")
            if frame_payload != expected_echo[1]:
                fail("target echo payload mismatch")
            return True
        else:
            fail("target sent an unexpected frame type")
        return False

    def drain_for(duration):
        until = time.monotonic() + duration
        while time.monotonic() < until:
            receive(until)

    total = count + int(idle)
    for seq in range(total):
        if seq == count:
            drain_for(4)
            payload = ("after-idle-%d" % cid).encode("ascii")
        else:
            if seq and spacing:
                drain_for(spacing)
            payload = ("client-%d-%d" % (cid, seq)).encode("ascii")
        sock.sendall(make_frame(FRAME_CLIENT, cid, seq, nonce, payload))
        with STATS_LOCK:
            STATS["client_frames"] += 1
        deadline = time.monotonic() + 8
        while not receive(deadline, (seq, payload)):
            if time.monotonic() >= deadline:
                fail("target echo deadline expired")
    # Fast exchanges may finish their echoes before the first periodic S frame.
    # Still require a fresh one here, even if the caller already read an initial
    # S frame to prove the target accepted the hello before a cohort barrier.
    while server_seq == first_server_seq:
        receive(last_server + progress_window)
    if time.monotonic() - last_server >= progress_window:
        fail("unsolicited server frames stopped progressing in the final window")


def tunnel_once(protocol, proxy, target, creds, cid, atyp="ipv4"):
    if protocol == "socks5":
        sock = socks5_connect(proxy, target, creds, atyp)
    else:
        sock = http_connect(proxy, target, creds)
    nonce = new_nonce()
    try:
        sock.sendall(make_frame(FRAME_HELLO, cid, 0, nonce, b"hello"))
        exchange(sock, cid, nonce, count=4, idle=True)
    finally:
        sock.close()
    with STATS_LOCK:
        STATS["tunnels"] += 1


def longlived_tunnel(proxy, target, creds, cid, frames=24, spacing=0.5):
    """SPEC 6:228: one long-lived framed bidirectional tunnel.

    Distinct from tunnel_once's idle-then-resume (6:229): rather than a single
    gap, this holds one socket open across many frames spaced over time -- ~12s
    at the defaults -- so a proxy that only survives a brief pause but drops a
    genuinely sustained connection is caught here and not there. The exchange
    itself is the shared one: every echo is matched on its own sequence, nonce and
    payload, and the target's unsolicited server frames must keep arriving, which
    the `spacing` between frames stretches across the tunnel's whole lifetime.

    Counted into STATS exactly as tunnel_once counts a tunnel, so the target's
    totals still reconcile in run_xray_mixed.sh.
    """
    sock = socks5_connect(proxy, target, creds, "ipv4")
    nonce = new_nonce()
    try:
        sock.sendall(make_frame(FRAME_HELLO, cid, 0, nonce, b"hello"))
        exchange(sock, cid, nonce, count=frames, spacing=spacing)
    finally:
        sock.close()
    with STATS_LOCK:
        STATS["tunnels"] += 1


def concurrency(protocol, proxy, target, creds, count, timeout=15):
    # Both barriers are essential: nobody sends C until every target has read H,
    # and nobody closes until every peer has validated all its echoed frames.
    # The independent target records occupancy during C, scoped by H's cohort
    # label so the background long-lived tunnel cannot inflate this proof.
    barrier = threading.Barrier(count, timeout=timeout)

    def member(index):
        sock = None
        try:
            if barrier.broken:
                fail("cohort aborted before connection establishment")
            cid = 1000 + index
            nonce = new_nonce()
            if protocol == "socks5":
                sock = socks5_connect(proxy, target, creds)
            else:
                sock = http_connect(proxy, target, creds)
            sock.sendall(make_frame(FRAME_HELLO, cid, 0, nonce,
                                    ("cohort-%d" % count).encode("ascii")))
            validate_server_frame(read_frame(sock, time.monotonic() + 8), cid, nonce, 0)
            barrier.wait()
            # Five C frames preserves the previous four + post-idle frame totals;
            # the separate tunnel_once cases still test the four-second idle.
            exchange(sock, cid, nonce, count=5, spacing=0.1, server_seq=1)
            barrier.wait()
            with STATS_LOCK:
                STATS["tunnels"] += 1
        except BaseException:
            barrier.abort()
            raise
        finally:
            if sock is not None:
                sock.close()

    with concurrent.futures.ThreadPoolExecutor(max_workers=count) as pool:
        futures = [pool.submit(member, i) for i in range(count)]
        for future in futures:
            future.result()


def direct_control(endpoint):
    """Prove the endpoint resolves and answers, reaching it without the proxy.

    The boundary cases below read a refusal from the absence of data, because Xray
    replies 0x00 to every CONNECT it accepts: measured against 26.3.27, a
    blackholed destination, a name that does not resolve, and a reachable target
    all return the same code. Without this control a name Xray cannot resolve is
    indistinguishable from a destination the boundary refused, and the hostname
    case would pass for the wrong reason.

    Counted apart from the tunnels so the target's totals still reconcile exactly.
    """
    try:
        sock = connect(endpoint)
    except OSError as exc:
        fail("control connection to %s did not open: %s"
             % (endpoint.host, type(exc).__name__))
    try:
        deadline = time.monotonic() + 8
        nonce = new_nonce()
        sock.sendall(make_frame(FRAME_HELLO, BOUNDARY_CID, 0, nonce, b"hello"))
        sock.sendall(make_frame(FRAME_CLIENT, BOUNDARY_CID, 0, nonce, b"control"))
        with STATS_LOCK:
            STATS["control_tunnels"] += 1
            STATS["control_frames"] += 1
        # The target also sends unsolicited server frames, so read until the echo.
        while True:
            kind, ids, frame_nonce, payload = read_frame(sock, deadline)
            if ids[0] != BOUNDARY_CID or frame_nonce != nonce:
                fail("control frame identity mismatch")
            if kind == FRAME_ECHO:
                if payload != b"control":
                    fail("control echo payload mismatch")
                return
            if kind != FRAME_SERVER:
                fail("control connection sent an unexpected frame type")
    finally:
        sock.close()


def socks5_denied_destination(proxy, target, creds, timeout=8, atyp="ipv4"):
    """True when the proxy refuses a destination inside the SPEC 3 boundary.

    The credentials are correct and the duplex target is answering at `target`, so
    a bypass is observed rather than inferred. A refusal is a non-zero SOCKS5
    reply, or a granted tunnel that carries nothing in either direction.

    The target does not speak until it is spoken to, and it only speaks to a
    connection that opens with a hello frame, so silence on its own proves
    nothing: the same opening a real tunnel uses goes out and any byte coming back
    is a bypass. Those frames are deliberately kept out of STATS, because on the
    refusal path the target never receives them and the counter reconciliation
    compares the two.

    Post-grant silence counts as a refusal only after that opening. A ProbeTimeout
    earlier still propagates: a negative probe must never report its own failure
    as proof.
    """
    sock = connect(proxy)
    try:
        deadline = time.monotonic() + timeout
        if not socks5_negotiate(sock, deadline):
            return True
        if not socks5_authenticate(sock, creds, deadline):
            fail("SOCKS5 rejected correct credentials on the boundary probe")
        sock.sendall(
            b"\x05\x01\x00"
            + socks5_target_address(atyp, target.host)
            + struct.pack("!H", target.port)
        )
        reply = read_exact(sock, 4, deadline)
        if reply[0] != 5 or reply[1] != 0:
            return True
        if reply[3] == 1:
            read_exact(sock, 6, deadline)
        elif reply[3] == 3:
            read_exact(sock, read_exact(sock, 1, deadline)[0] + 2, deadline)
        elif reply[3] == 4:
            read_exact(sock, 18, deadline)
        else:
            fail("SOCKS5 returned an unknown address type on the boundary probe")
        nonce = new_nonce()
        sock.sendall(make_frame(FRAME_HELLO, BOUNDARY_CID, 0, nonce, b"hello"))
        sock.sendall(make_frame(FRAME_CLIENT, BOUNDARY_CID, 0, nonce, b"probe"))
        try:
            recv_bounded(sock, 1, deadline)
        except (PeerClosed, ProbeTimeout):
            return True
        return False
    except (ConnectionError, OSError, PeerClosed):
        return True
    finally:
        sock.close()


def ipv6_target_available(address):
    if not socket.has_ipv6:
        return False
    try:
        probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    except OSError:
        return False
    try:
        probe.bind((address, 0))
    except OSError:
        return False
    finally:
        probe.close()
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--target-host", default="192.0.2.1")
    parser.add_argument("--target-hostname", default="xray-target.test")
    parser.add_argument("--target-ipv6", default="2001:db8::1")
    parser.add_argument("--denied-host", default="127.0.0.1")
    parser.add_argument("--denied-hostname", default="denied-target.test")
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--passfile", required=True)
    parser.add_argument("--stats-file")
    args = parser.parse_args()
    user, password = read_passfile(args.passfile)
    proxy = Endpoint(args.host, args.port)
    target = Endpoint(args.target_host, args.target_port)
    creds = Credentials(user, password)
    bad_creds = Credentials(user, wrong_password(password))

    # SPEC 6:228: one long-lived framed bidirectional tunnel. Started here and
    # joined at the end so its ~12s hold overlaps the target, boundary, auth and
    # concurrency cases rather than adding its wall-clock on top of theirs -- a
    # cost otherwise paid in full in every driving CI job. STATS is lock-guarded
    # and cid 500 is clear of every other case (1-4, 176, 1000+), so the overlap
    # changes only timing, not what is counted; and a connection that survives the
    # 128-way burst alongside it is a stronger sustained-tunnel proof, not a weaker
    # one. Its marker is not printed until result() has re-raised any failure.
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as longlived_pool:
        longlived = longlived_pool.submit(longlived_tunnel, proxy, target, creds, 500)

        # SPEC 6 records the IPv4-literal, hostname and IPv6 target paths
        # separately. IPv6 is conditional on the host having the target address, so an
        # environment without it reports unavailable rather than silently passing.
        tunnel_once("socks5", proxy, target, creds, 1, "ipv4")
        print("mixed_target_ipv4=ok")
        tunnel_once("http", proxy, target, creds, 2)
        print("mixed_http_connect=ok")
        tunnel_once("socks5", proxy, Endpoint(args.target_hostname, args.target_port), creds, 3, "hostname")
        print("mixed_target_hostname=ok")
        if ipv6_target_available(args.target_ipv6):
            tunnel_once("socks5", proxy, Endpoint(args.target_ipv6, args.target_port), creds, 4, "ipv6")
            print("mixed_target_ipv6=ok")
        else:
            print("mixed_target_ipv6=unavailable")
        # SPEC 3 and 7: the destination boundary. The controls come first: they reach
        # the denied endpoint, by address and by name, without the proxy, so a refusal
        # below is attributable to the boundary and not to a dead listener or a name
        # nothing can resolve.
        denied = Endpoint(args.denied_host, args.target_port)
        denied_by_name = Endpoint(args.denied_hostname, args.target_port)
        direct_control(denied)
        direct_control(denied_by_name)
        print("mixed_denied_control=ok")
        if not socks5_denied_destination(proxy, denied, creds):
            fail("mixed proxy reached a destination inside the boundary")
        print("mixed_denied_destination=ok")
        # The literal case above cannot tell IPIfNonMatch from the default AsIs. This
        # one can: the request carries a name, so only a proxy that resolves it before
        # routing sees an address inside the boundary at all.
        if not socks5_denied_destination(proxy, denied_by_name, creds, atyp="hostname"):
            fail("mixed proxy reached a hostname resolving inside the boundary")
        print("mixed_denied_hostname=ok")
        if not socks5_wrong_auth(proxy, bad_creds):
            fail("SOCKS5 accepted incorrect credentials")
        if not http_wrong_auth(proxy, target, bad_creds):
            fail("HTTP proxy accepted incorrect credentials")
        if not socks5_noauth(proxy):
            fail("mixed proxy accepted unauthenticated SOCKS5")
        if not socks4_rejected(proxy, target, creds, False):
            fail("mixed proxy accepted SOCKS4")
        if not socks4_rejected(proxy, target, creds, True):
            fail("mixed proxy accepted SOCKS4a")
        if not socks5_reject_command(proxy, target, creds, 2):
            fail("mixed proxy accepted BIND")
        if not socks5_reject_command(proxy, target, creds, 3):
            fail("mixed proxy accepted UDP ASSOCIATE with udp=false")
        for count in (1, 32, 128):
            concurrency("socks5", proxy, target, creds, count)
            print("mixed_concurrency_%d=ok" % count)
        # Join the long-lived tunnel started at the top; result() re-raises anything
        # it hit, so the marker follows only a genuinely completed sustained tunnel.
        longlived.result(timeout=60)
    print("mixed_longlived=ok")
    print("mixed_protocol=ok")
    if args.stats_file:
        with open(args.stats_file, "w", encoding="ascii") as handle:
            handle.write(json.dumps(STATS, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:
        sys.stderr.write("xray-mixed: %s\n" % exc)
        sys.exit(ERROR)
