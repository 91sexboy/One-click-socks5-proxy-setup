#!/usr/bin/env python3
"""Local framed TCP target for Xray mixed-proxy CI tests."""

import argparse
import json
import os
import select
import signal
import socket
import struct
import threading

MAGIC = b"X5"
HEADER = 2 + 1 + 4 + 4 + 8
STOP = threading.Event()
# Reentrant: write_metrics takes this lock itself, and the accept path calls it
# with the lock already held so the count it flushes is the one it just bumped.
COUNT_LOCK = threading.RLock()
ACCEPTED = 0
FRAMES = 0
FAMILIES = []


def write_text(path, text):
    # The temporary is unique per call: two writers sharing one name truncate each
    # other's bytes, and the loser of the rename has no source left to rename.
    tmp = "%s.%s.tmp" % (path, os.urandom(6).hex())
    with open(tmp, "w", encoding="ascii") as handle:
        handle.write(text)
    os.replace(tmp, path)


def write_metrics(count_path, report_path):
    """Flush the counters, serialised against every other writer of them.

    main leaves its accept loop one select timeout after STOP while workers linger
    up to their socket timeout, so its last flush overlaps theirs. The gate
    reconciles its own frame counts against this report, and a spliced one fails
    the run on a confusing error instead of the real outcome.
    """
    with COUNT_LOCK:
        data = {"accepted": ACCEPTED, "frames": FRAMES, "families": list(FAMILIES)}
        if count_path:
            write_text(count_path, str(ACCEPTED) + "\n")
        if report_path:
            write_text(report_path, json.dumps(data, sort_keys=True) + "\n")


def read_exact(sock, size):
    data = bytearray()
    while len(data) < size:
        try:
            chunk = sock.recv(size - len(data))
        except socket.timeout:
            if STOP.is_set():
                raise EOFError("target stopping")
            continue
        if not chunk:
            raise EOFError("target connection closed")
        data.extend(chunk)
    return bytes(data)


def frame(kind, cid, seq, nonce, payload):
    body = bytes([kind]) + struct.pack("!II", cid, seq) + nonce + payload
    return MAGIC + struct.pack("!I", len(body)) + body


def parse_frame(data):
    if len(data) < HEADER or data[:2] != MAGIC:
        raise ValueError("invalid frame header")
    length = struct.unpack("!I", data[2:6])[0]
    body = data[6:]
    if length != len(body) or length < 1 + 4 + 4 + 8:
        raise ValueError("invalid frame length")
    kind = body[0]
    cid, seq = struct.unpack("!II", body[1:9])
    return kind, cid, seq, body[9:17], body[17:]


class FrameWriter:
    """Serialises frame writes for one connection.

    Each frame goes out in two pieces so the client has to reassemble it. Two
    threads write a connection -- the echo path and the server-frame sender -- so
    without this lock their pieces interleave and the client parses a spliced
    header. With a small frame the split lands inside the cid field, so the
    corruption surfaces as a wrong cid and nonce rather than as a bad magic.
    """

    def __init__(self, sock):
        self._sock = sock
        self._lock = threading.Lock()

    def send(self, data):
        split = max(1, len(data) // 3)
        with self._lock:
            self._sock.sendall(data[:split])
            self._sock.sendall(data[split:])


def serve_connection(sock, count_path, report_path):
    global FRAMES
    sock.settimeout(1.0)
    try:
        first = read_exact(sock, 6)
        length = struct.unpack("!I", first[2:6])[0]
        rest = read_exact(sock, length)
        kind, cid, seq, nonce, payload = parse_frame(first + rest)
        if kind != ord("H"):
            return
        sender_stop = threading.Event()
        writer = FrameWriter(sock)

        def send_server_frames():
            server_seq = 0
            while not sender_stop.wait(0.25):
                try:
                    writer.send(frame(ord("S"), cid, server_seq, nonce, b"server-" + str(server_seq).encode("ascii")))
                    server_seq += 1
                except OSError:
                    return

        sender = threading.Thread(target=send_server_frames, daemon=True)
        sender.start()
        while not STOP.is_set():
            try:
                head = read_exact(sock, 6)
                length = struct.unpack("!I", head[2:6])[0]
                body = read_exact(sock, length)
            except socket.timeout:
                continue
            except EOFError:
                return
            kind, frame_cid, frame_seq, frame_nonce, frame_payload = parse_frame(head + body)
            if kind != ord("C") or frame_cid != cid or frame_nonce != nonce:
                return
            with COUNT_LOCK:
                FRAMES += 1
            writer.send(frame(ord("E"), cid, frame_seq, nonce, frame_payload))
    except (EOFError, OSError, ValueError):
        return
    finally:
        try:
            sender_stop.set()
        except UnboundLocalError:
            pass
        sock.close()
        # Flushed here as well as on accept so the report is readable, and final
        # for every closed tunnel, while the target is still running.
        write_metrics(count_path, report_path)


def make_listeners(host, port, host6):
    """Bind one port on IPv4 and, where host6 is usable, on IPv6 as well.

    SPEC 6 records the IPv4-literal, hostname and IPv6 target paths separately,
    and all three have to arrive at the same target port.
    """
    v4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    v4.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    v4.bind((host, port))
    v4.listen(256)
    listeners = [v4]
    FAMILIES.append("ipv4")
    bound = v4.getsockname()[1]
    if socket.has_ipv6:
        v6 = None
        try:
            v6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            v6.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            v6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            v6.bind((host6, bound))
            v6.listen(256)
        except OSError:
            if v6 is not None:
                v6.close()
        else:
            listeners.append(v6)
            FAMILIES.append("ipv6")
    return listeners, bound


def serve(listeners, count_path, report_path):
    global ACCEPTED
    while not STOP.is_set():
        try:
            ready = select.select(listeners, [], [], 0.5)[0]
        except OSError:
            return
        for listener in ready:
            try:
                sock, _ = listener.accept()
            except OSError:
                continue
            with COUNT_LOCK:
                ACCEPTED += 1
                write_metrics(count_path, report_path)
            thread = threading.Thread(
                target=serve_connection, args=(sock, count_path, report_path), daemon=True
            )
            thread.start()


def stop_handler(signum, frame_info):
    STOP.set()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--host6", default="::1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--count-file", required=True)
    parser.add_argument("--report-file", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop_handler)
    signal.signal(signal.SIGINT, stop_handler)
    listeners, bound = make_listeners(args.host, args.port, args.host6)
    write_text(args.ready_file, str(bound) + "\n")
    write_metrics(args.count_file, args.report_file)
    try:
        serve(listeners, args.count_file, args.report_file)
    finally:
        for listener in listeners:
            listener.close()
        write_metrics(args.count_file, args.report_file)


if __name__ == "__main__":
    main()
