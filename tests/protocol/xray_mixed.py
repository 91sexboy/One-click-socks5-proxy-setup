#!/usr/bin/env python3
"""CI-only SOCKS5/HTTP mixed proxy and duplex transport probe."""

import argparse
import base64
import collections
import concurrent.futures
import json
import os
import socket
import struct
import sys
import threading
import time

ERROR = 2
FRAME_MAGIC = b"X5"
# The boundary probe's connection id. Kept clear of the data-plane tunnels, which
# use 1-4 and 1000 upwards, so a frame from either is attributable.
BOUNDARY_CID = 176
STATS_LOCK = threading.Lock()
STATS = {"tunnels": 0, "client_frames": 0}

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


def socks5_connect(proxy, target, creds, atyp="ipv4"):
    sock = connect(proxy)
    deadline = time.monotonic() + 10
    sock.sendall(b"\x05\x01\x02")
    reply = read_exact(sock, 2, deadline)
    if reply != b"\x05\x02":
        fail("SOCKS5 did not select username/password authentication")
    ub = creds.user.encode("ascii")
    pb = creds.password.encode("ascii")
    sock.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
    auth = read_exact(sock, 2, deadline)
    if auth != b"\x01\x00":
        sock.close()
        fail("SOCKS5 credentials were rejected")
    sock.sendall(b"\x05\x01\x00" + socks5_target_address(atyp, target.host) + struct.pack("!H", target.port))
    head = read_exact(sock, 4, deadline)
    if head[0] != 5 or head[1] != 0:
        sock.close()
        fail("SOCKS5 CONNECT was refused")
    if head[3] == 1:
        read_exact(sock, 6, deadline)
    elif head[3] == 3:
        length = read_exact(sock, 1, deadline)[0]
        read_exact(sock, length + 2, deadline)
    elif head[3] == 4:
        read_exact(sock, 18, deadline)
    else:
        sock.close()
        fail("SOCKS5 returned an unknown address type")
    return sock


def http_connect(proxy, target, creds):
    sock = connect(proxy)
    token = base64.b64encode((creds.user + ":" + creds.password).encode("ascii")).decode("ascii")
    authority = http_authority(target)
    request = (
        "CONNECT %s HTTP/1.1\r\n"
        "Host: %s\r\n"
        "Proxy-Authorization: Basic %s\r\n"
        "Connection: keep-alive\r\n\r\n"
    ) % (authority, authority, token)
    sock.sendall(request.encode("ascii"))
    deadline = time.monotonic() + 10
    response = bytearray()
    while b"\r\n\r\n" not in response:
        if time.monotonic() >= deadline:
            sock.close()
            fail("HTTP CONNECT response deadline expired")
        sock.settimeout(max(0.05, deadline - time.monotonic()))
        chunk = sock.recv(4096)
        if not chunk:
            sock.close()
            fail("HTTP proxy closed before CONNECT response")
        response.extend(chunk)
        if len(response) > 16384:
            sock.close()
            fail("HTTP CONNECT response is too large")
    line = bytes(response).split(b"\r\n", 1)[0]
    if not line.startswith(b"HTTP/1.1 200") and not line.startswith(b"HTTP/1.0 200"):
        sock.close()
        fail("HTTP CONNECT was not accepted")
    return sock


def socks5_wrong_auth(proxy, creds):
    sock = connect(proxy)
    try:
        sock.sendall(b"\x05\x01\x02")
        reply = read_exact(sock, 2, time.monotonic() + 5)
        if reply != b"\x05\x02":
            return True
        ub = creds.user.encode("ascii")
        pb = creds.password.encode("ascii")
        sock.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
        reply = read_exact(sock, 2, time.monotonic() + 5)
        return reply != b"\x01\x00"
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
        sock.sendall(b"\x05\x01\x02")
        if read_exact(sock, 2, deadline) != b"\x05\x02":
            return True
        ub = creds.user.encode("ascii")
        pb = creds.password.encode("ascii")
        sock.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
        if read_exact(sock, 2, deadline) != b"\x01\x00":
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
        authority = http_authority(target)
        token = base64.b64encode((creds.user + ":" + creds.password).encode("ascii")).decode("ascii")
        request = (
            "CONNECT %s HTTP/1.1\r\nHost: %s\r\n"
            "Proxy-Authorization: Basic %s\r\n\r\n"
        ) % (authority, authority, token)
        sock.sendall(request.encode("ascii"))
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


def exchange(sock, cid, nonce, count=4, idle=False):
    seen_echo = set()
    seen_server = set()
    for seq in range(count):
        payload = ("client-%d-%d" % (cid, seq)).encode("ascii")
        sock.sendall(make_frame(ord("C"), cid, seq, nonce, payload))
        with STATS_LOCK:
            STATS["client_frames"] += 1
        deadline = time.monotonic() + 8
        while seq not in seen_echo:
            kind, ids, frame_nonce, frame_payload = read_frame(sock, deadline)
            if ids[0] != cid or frame_nonce != nonce:
                fail("target frame identity mismatch")
            if kind == ord("E"):
                if ids[1] != seq or frame_payload != payload:
                    fail("target echo payload mismatch")
                seen_echo.add(seq)
            elif kind == ord("S"):
                seen_server.add(ids[1])
            else:
                fail("target sent an unexpected frame type")
    if idle:
        time.sleep(4)
        payload = ("after-idle-%d" % cid).encode("ascii")
        sock.sendall(make_frame(ord("C"), cid, count, nonce, payload))
        with STATS_LOCK:
            STATS["client_frames"] += 1
        deadline = time.monotonic() + 8
        while count not in seen_echo:
            kind, ids, frame_nonce, frame_payload = read_frame(sock, deadline)
            if ids[0] != cid or frame_nonce != nonce:
                fail("post-idle frame identity mismatch")
            if kind == ord("E"):
                if ids[1] != count or frame_payload != payload:
                    fail("post-idle echo mismatch")
                seen_echo.add(count)
            elif kind == ord("S"):
                seen_server.add(ids[1])
            else:
                fail("unexpected post-idle frame type")
    if not seen_server:
        fail("target never sent an unsolicited server frame")


def tunnel_once(protocol, proxy, target, creds, cid, atyp="ipv4"):
    if protocol == "socks5":
        sock = socks5_connect(proxy, target, creds, atyp)
    else:
        sock = http_connect(proxy, target, creds)
    nonce = struct.pack("!Q", cid * 104729 + 17)
    try:
        sock.sendall(make_frame(ord("H"), cid, 0, nonce, b"hello"))
        exchange(sock, cid, nonce, count=4, idle=True)
    finally:
        sock.close()
    with STATS_LOCK:
        STATS["tunnels"] += 1


def concurrency(protocol, proxy, target, creds, count):
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(count, 64)) as pool:
        futures = [pool.submit(tunnel_once, protocol, proxy, target, creds, 1000 + i) for i in range(count)]
        for future in futures:
            future.result(timeout=45)


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
        sock.sendall(b"\x05\x01\x02")
        if read_exact(sock, 2, deadline) != b"\x05\x02":
            return True
        ub = creds.user.encode("ascii")
        pb = creds.password.encode("ascii")
        sock.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
        if read_exact(sock, 2, deadline) != b"\x01\x00":
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
        nonce = struct.pack("!Q", BOUNDARY_CID * 104729 + 17)
        sock.sendall(make_frame(ord("H"), BOUNDARY_CID, 0, nonce, b"hello"))
        sock.sendall(make_frame(ord("C"), BOUNDARY_CID, 0, nonce, b"probe"))
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
    # SPEC 3 and 7: the destination boundary. The tunnels above are the positive
    # control -- if the proxy were simply broken they would have failed first --
    # so a refusal here is attributable to the boundary and not to a dead engine.
    # The same target answers at the denied address, so a bypass is observed.
    if not socks5_denied_destination(proxy, Endpoint(args.denied_host, args.target_port), creds):
        fail("mixed proxy reached a destination inside the boundary")
    print("mixed_denied_destination=ok")
    # The literal case above cannot tell IPIfNonMatch from the default AsIs. This
    # one can: the request carries a name, so only a proxy that resolves it before
    # routing sees an address inside the boundary at all.
    if not socks5_denied_destination(
            proxy, Endpoint(args.denied_hostname, args.target_port), creds,
            atyp="hostname"):
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
