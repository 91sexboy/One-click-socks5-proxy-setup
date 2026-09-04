#!/usr/bin/env python3
"""CI-only SOCKS5/HTTP mixed proxy and duplex transport probe."""

import argparse
import base64
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
STATS_LOCK = threading.Lock()
STATS = {"tunnels": 0, "client_frames": 0}


def fail(message):
    raise RuntimeError(message)


def read_exact(sock, size, deadline):
    data = bytearray()
    while len(data) < size:
        if time.monotonic() >= deadline:
            fail("read deadline expired")
        sock.settimeout(max(0.05, deadline - time.monotonic()))
        chunk = sock.recv(size - len(data))
        if not chunk:
            fail("connection closed before the expected data arrived")
        data.extend(chunk)
    return bytes(data)


def connect(host, port, timeout=10.0):
    sock = socket.create_connection((host, port), timeout=timeout)
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


def http_authority(host, port):
    if ":" in host:
        return "[%s]:%d" % (host, port)
    return "%s:%d" % (host, port)


def socks5_connect(proxy_host, proxy_port, target_host, target_port, user, password, atyp="ipv4"):
    sock = connect(proxy_host, proxy_port)
    deadline = time.monotonic() + 10
    sock.sendall(b"\x05\x01\x02")
    reply = read_exact(sock, 2, deadline)
    if reply != b"\x05\x02":
        fail("SOCKS5 did not select username/password authentication")
    ub = user.encode("ascii")
    pb = password.encode("ascii")
    sock.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
    auth = read_exact(sock, 2, deadline)
    if auth != b"\x01\x00":
        sock.close()
        fail("SOCKS5 credentials were rejected")
    sock.sendall(b"\x05\x01\x00" + socks5_target_address(atyp, target_host) + struct.pack("!H", target_port))
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


def http_connect(proxy_host, proxy_port, target_host, target_port, user, password):
    sock = connect(proxy_host, proxy_port)
    token = base64.b64encode((user + ":" + password).encode("ascii")).decode("ascii")
    authority = http_authority(target_host, target_port)
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


def socks5_wrong_auth(proxy_host, proxy_port, user, password):
    sock = connect(proxy_host, proxy_port)
    try:
        sock.sendall(b"\x05\x01\x02")
        reply = read_exact(sock, 2, time.monotonic() + 5)
        if reply != b"\x05\x02":
            return True
        ub = user.encode("ascii")
        pb = password.encode("ascii")
        sock.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
        reply = read_exact(sock, 2, time.monotonic() + 5)
        return reply != b"\x01\x00"
    except (ConnectionError, OSError, RuntimeError):
        return True
    finally:
        sock.close()


def socks5_noauth(proxy_host, proxy_port):
    sock = connect(proxy_host, proxy_port)
    try:
        sock.sendall(b"\x05\x01\x00")
        reply = sock.recv(2)
        return reply != b"\x05\x00"
    except (ConnectionError, OSError):
        return True
    finally:
        sock.close()


def socks5_reject_command(proxy_host, proxy_port, target_host, target_port, user, password, command):
    sock = connect(proxy_host, proxy_port)
    try:
        deadline = time.monotonic() + 8
        sock.sendall(b"\x05\x01\x02")
        if read_exact(sock, 2, deadline) != b"\x05\x02":
            return True
        ub = user.encode("ascii")
        pb = password.encode("ascii")
        sock.sendall(b"\x01" + bytes([len(ub)]) + ub + bytes([len(pb)]) + pb)
        if read_exact(sock, 2, deadline) != b"\x01\x00":
            return True
        sock.sendall(b"\x05" + bytes([command, 0, 1]) + socket.inet_aton(target_host) + struct.pack("!H", target_port))
        reply = read_exact(sock, 4, deadline)
        return reply[0] != 5 or reply[1] != 0
    except (ConnectionError, OSError, RuntimeError):
        return True
    finally:
        sock.close()


def socks4_rejected(proxy_host, proxy_port, target_host, target_port, user, socks4a):
    sock = connect(proxy_host, proxy_port)
    try:
        addr = socket.inet_aton("0.0.0.1" if socks4a else target_host)
        request = b"\x04\x01" + struct.pack("!H", target_port) + addr + user.encode("ascii") + b"\x00"
        if socks4a:
            request += target_host.encode("ascii") + b"\x00"
        sock.sendall(request)
        reply = sock.recv(8)
        return len(reply) < 2 or reply[1] != 0x5A
    except (ConnectionError, OSError):
        return True
    finally:
        sock.close()


def http_wrong_auth(proxy_host, proxy_port, target_host, target_port, user, password):
    sock = connect(proxy_host, proxy_port)
    try:
        token = base64.b64encode((user + ":" + password).encode("ascii")).decode("ascii")
        request = (
            "CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d\r\n"
            "Proxy-Authorization: Basic %s\r\n\r\n"
        ) % (target_host, target_port, target_host, target_port, token)
        sock.sendall(request.encode("ascii"))
        sock.settimeout(5)
        response = sock.recv(4096)
        return response.startswith(b"HTTP/1.1 407") or response.startswith(b"HTTP/1.0 407") or not response
    except (ConnectionError, OSError):
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


def tunnel_once(protocol, proxy_host, proxy_port, target_host, target_port, user, password, cid, atyp="ipv4"):
    if protocol == "socks5":
        sock = socks5_connect(proxy_host, proxy_port, target_host, target_port, user, password, atyp)
    else:
        sock = http_connect(proxy_host, proxy_port, target_host, target_port, user, password)
    nonce = struct.pack("!Q", cid * 104729 + 17)
    try:
        sock.sendall(make_frame(ord("H"), cid, 0, nonce, b"hello"))
        exchange(sock, cid, nonce, count=4, idle=True)
    finally:
        sock.close()
    with STATS_LOCK:
        STATS["tunnels"] += 1


def concurrency(protocol, args, user, password, count):
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(count, 64)) as pool:
        futures = [pool.submit(tunnel_once, protocol, args.host, args.port, args.target_host, args.target_port, user, password, 1000 + i) for i in range(count)]
        for future in futures:
            future.result(timeout=45)


def ipv6_loopback_available():
    if not socket.has_ipv6:
        return False
    try:
        probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    except OSError:
        return False
    try:
        probe.bind(("::1", 0))
    except OSError:
        return False
    finally:
        probe.close()
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-hostname", default="localhost")
    parser.add_argument("--target-ipv6", default="::1")
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--passfile", required=True)
    parser.add_argument("--stats-file")
    args = parser.parse_args()
    user, password = read_passfile(args.passfile)
    bad_password = wrong_password(password)

    # SPEC 6 records the IPv4-literal, hostname and IPv6 target paths
    # separately. IPv6 is conditional on the host having a usable ::1, so an
    # environment without it reports unavailable rather than silently passing.
    tunnel_once("socks5", args.host, args.port, args.target_host, args.target_port, user, password, 1, "ipv4")
    print("mixed_target_ipv4=ok")
    tunnel_once("http", args.host, args.port, args.target_host, args.target_port, user, password, 2)
    print("mixed_http_connect=ok")
    tunnel_once("socks5", args.host, args.port, args.target_hostname, args.target_port, user, password, 3, "hostname")
    print("mixed_target_hostname=ok")
    if ipv6_loopback_available():
        tunnel_once("socks5", args.host, args.port, args.target_ipv6, args.target_port, user, password, 4, "ipv6")
        print("mixed_target_ipv6=ok")
    else:
        print("mixed_target_ipv6=unavailable")
    if not socks5_wrong_auth(args.host, args.port, user, bad_password):
        fail("SOCKS5 accepted incorrect credentials")
    if not http_wrong_auth(args.host, args.port, args.target_host, args.target_port, user, bad_password):
        fail("HTTP proxy accepted incorrect credentials")
    if not socks5_noauth(args.host, args.port):
        fail("mixed proxy accepted unauthenticated SOCKS5")
    if not socks4_rejected(args.host, args.port, args.target_host, args.target_port, user, False):
        fail("mixed proxy accepted SOCKS4")
    if not socks4_rejected(args.host, args.port, args.target_host, args.target_port, user, True):
        fail("mixed proxy accepted SOCKS4a")
    if not socks5_reject_command(args.host, args.port, args.target_host, args.target_port, user, password, 2):
        fail("mixed proxy accepted BIND")
    if not socks5_reject_command(args.host, args.port, args.target_host, args.target_port, user, password, 3):
        fail("mixed proxy accepted UDP ASSOCIATE with udp=false")
    for count in (1, 32, 128):
        concurrency("socks5", args, user, password, count)
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
