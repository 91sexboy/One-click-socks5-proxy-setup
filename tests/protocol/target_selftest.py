#!/usr/bin/env python3
"""Self-test for the duplex target's frame writer.

A frame is deliberately sent in two pieces so the client has to reassemble it.
Two threads write the same connection -- the echo path and the unsolicited
server-frame sender -- so those two pieces must not interleave. When they do, the
client reads a spliced stream: with a small frame the split lands inside the cid
field, so the header still parses and the mismatch surfaces as a wrong cid and
nonce rather than as a bad magic.

The interleaving here is forced rather than raced: the first writer holds a fixed
gap between its two pieces and the second writer starts inside that gap. A writer
that serialises correctly makes the second wait, so this is deterministic in both
directions and never deadlocks.
"""

import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import duplex_target  # noqa: E402

FAILURES = []
CHECKS = []


def check(label, ok):
    CHECKS.append(label)
    if ok:
        print("ok - %s" % label)
    else:
        print("not ok - %s" % label)
        FAILURES.append(label)


class GappedSocket:
    """Wraps a socket and holds a fixed gap after the first send of each frame."""

    def __init__(self, sock, gap):
        self._sock = sock
        self._gap = gap
        self._seen = 0

    def sendall(self, data):
        self._sock.sendall(data)
        self._seen += 1
        if self._seen % 2 == 1 and self._gap:
            time.sleep(self._gap)


def read_frames(sock, expected, deadline):
    frames = []
    buffered = b""
    while len(frames) < expected:
        if time.monotonic() >= deadline:
            break
        sock.settimeout(max(0.05, deadline - time.monotonic()))
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        buffered += chunk
        while len(buffered) >= 6:
            if buffered[:2] != duplex_target.MAGIC:
                return frames, "spliced stream: magic is %r" % buffered[:2]
            length = struct.unpack("!I", buffered[2:6])[0]
            if len(buffered) < 6 + length:
                break
            body = buffered[6:6 + length]
            buffered = buffered[6 + length:]
            frames.append((body[0], struct.unpack("!II", body[1:9])[0], body[9:17]))
    return frames, None


def main():
    reader, writer_sock = socket.socketpair()
    try:
        writer = duplex_target.FrameWriter(GappedSocket(writer_sock, 0.05))
        echo = duplex_target.frame(ord("E"), 4242, 7, b"NONCE-AA", b"echo")
        server = duplex_target.frame(ord("S"), 4242, 0, b"NONCE-AA", b"server-0")

        first = threading.Thread(target=writer.send, args=(echo,))
        second = threading.Thread(target=writer.send, args=(server,))
        first.start()
        time.sleep(0.01)
        second.start()
        first.join(10)
        second.join(10)
        check("both writers finished", not first.is_alive() and not second.is_alive())

        frames, problem = read_frames(reader, 2, time.monotonic() + 5)
        check("the stream carries no spliced frame", problem is None)
        if problem:
            print("# %s" % problem)
        check("both frames arrived intact", len(frames) == 2)
        kinds = sorted(f[0] for f in frames)
        check("one echo and one server frame", kinds == sorted([ord("E"), ord("S")]))
        check("every frame keeps its cid", all(f[1] == 4242 for f in frames))
        check("every frame keeps its nonce", all(f[2] == b"NONCE-AA" for f in frames))
    finally:
        reader.close()
        writer_sock.close()

    print("TESTS %d %d" % (len(CHECKS) - len(FAILURES), len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
