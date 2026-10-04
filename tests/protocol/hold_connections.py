#!/usr/bin/env python3
"""Hold N verified tunnels open so memory can be sampled under load.

SPEC 8 wants separate idle/1/32/128-connection peaks. Sampling a service that
has no connections open measures only the idle case, so the load has to be held
still while the sampler reads the cgroup.

A socket object is not a held connection: SPEC 6 does not take a granted
handshake for a working data path, and Xray grants CONNECT before it dials. So
every tunnel completes one framed round trip -- connection id, nonce and
sequence checked on the echo -- before readiness is published. While held, the
holder reads and validates the target's periodic server frames on every tunnel,
so a closed or corrupted tunnel ends it with a failure. SIGUSR1 asks for one
more echo round on every tunnel; its answer is written to the check file.

Exit 0 means a stop request (SIGTERM or SIGINT) ended a healthy hold. Anything
else, including the hold deadline expiring first, exits 2 with a diagnostic
naming the tunnel and the step that failed. The ready and check files are
removed on every exit, so neither outlives the hold it describes.
"""

import argparse
import os
import select
import signal
import sys
import threading
import time

from duplex_target import write_text
import xray_mixed

STOP = threading.Event()
CHECK = threading.Event()
# Held cids start here, clear of the data-plane (1-4, 1000+) and boundary (176)
# tunnels, so a frame from any of them is attributable.
FIRST_CID = 5000


def stop(signum, frame_info):
    STOP.set()


def request_check(signum, frame_info):
    CHECK.set()


class HoldFailure(Exception):
    """One held tunnel failed; the message names it, its step and the cause."""


class HeldTunnel:
    def __init__(self, sock, cid, cohort):
        self.sock = sock
        self.cid = cid
        self.nonce = xray_mixed.new_nonce()
        self.stage = "hello"
        self.server_seq = 0
        self.client_seq = 0
        self.awaiting = None
        sock.sendall(xray_mixed.make_frame(xray_mixed.FRAME_HELLO, cid, 0, self.nonce,
                                           cohort.encode("ascii")))

    def failure(self, error):
        # The memory-compare diagnostic shape: which tunnel, doing what, and why.
        # Every message is a fixed literal or a socket error, never payload.
        return HoldFailure("held cid=%d stage=%s %s: %s" % (
            self.cid, self.stage, type(error).__name__, error))

    def send_echo_request(self):
        self.stage = "echo-send"
        payload = ("held-%d-%d" % (self.cid, self.client_seq)).encode("ascii")
        self.sock.sendall(xray_mixed.make_frame(xray_mixed.FRAME_CLIENT, self.cid,
                                                self.client_seq, self.nonce, payload))
        self.awaiting = (self.client_seq, payload)
        self.client_seq += 1
        self.stage = "echo-wait"

    def receive(self, deadline):
        """Read and validate one frame; True when it is the awaited echo."""
        frame = xray_mixed.read_frame(self.sock, deadline)
        kind, ids, nonce, payload = frame
        if kind == xray_mixed.FRAME_SERVER:
            xray_mixed.validate_server_frame(frame, self.cid, self.nonce, self.server_seq)
            self.server_seq += 1
            return False
        if kind != xray_mixed.FRAME_ECHO or self.awaiting is None:
            xray_mixed.fail("target sent an unexpected frame type")
        if ids != (self.cid, self.awaiting[0]) or nonce != self.nonce:
            xray_mixed.fail("target echo identity or sequence mismatch")
        if payload != self.awaiting[1]:
            xray_mixed.fail("target echo payload mismatch")
        self.awaiting = None
        self.stage = "held"
        return True


def guarded(tunnel, action, *args):
    try:
        return action(*args)
    except HoldFailure:
        raise
    except (RuntimeError, OSError, xray_mixed.ProbeTimeout, xray_mixed.PeerClosed) as error:
        raise tunnel.failure(error) from error


def echo_round(tunnels, seconds):
    """Every tunnel echoes one fresh frame before one monotonic deadline."""
    deadline = time.monotonic() + seconds
    for tunnel in tunnels:
        guarded(tunnel, tunnel.send_echo_request)
    pending = {tunnel.sock: tunnel for tunnel in tunnels}
    while pending:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            late = next(iter(pending.values()))
            raise late.failure(xray_mixed.ProbeTimeout(
                "%d of %d tunnels did not echo in time" % (len(pending), len(tunnels))))
        for sock in select.select(list(pending), [], [], remaining)[0]:
            tunnel = pending[sock]
            if guarded(tunnel, tunnel.receive, deadline):
                del pending[sock]


def drain(tunnels, seconds):
    """Validate whatever server frames arrive within `seconds`; EOF is a failure."""
    socks = {tunnel.sock: tunnel for tunnel in tunnels}
    for sock in select.select(list(socks), [], [], seconds)[0]:
        tunnel = socks[sock]
        tunnel.stage = "held"
        guarded(tunnel, tunnel.receive, time.monotonic() + 5)


def establish(proxy, target, creds, count, cohort, seconds):
    tunnels = []
    deadline = time.monotonic() + seconds
    try:
        for index in range(count):
            cid = FIRST_CID + index
            if time.monotonic() >= deadline:
                raise HoldFailure("held cid=%d stage=connect ProbeTimeout: establishment deadline expired" % cid)
            try:
                sock = xray_mixed.socks5_connect(proxy, target, creds, "ipv4")
            except (RuntimeError, OSError, xray_mixed.ProbeTimeout, xray_mixed.PeerClosed) as error:
                raise HoldFailure("held cid=%d stage=connect %s: %s" % (
                    cid, type(error).__name__, error)) from error
            try:
                tunnel = HeldTunnel(sock, cid, cohort)
            except OSError as error:
                sock.close()
                raise HoldFailure("held cid=%d stage=hello %s: %s" % (
                    cid, type(error).__name__, error)) from error
            tunnels.append(tunnel)
        echo_round(tunnels, max(0.0, deadline - time.monotonic()))
    except BaseException:
        close_all(tunnels)
        raise
    return tunnels


def close_all(tunnels):
    for tunnel in tunnels:
        try:
            tunnel.sock.close()
        except OSError:
            pass


def remove(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


def hold(tunnels, args):
    write_text(args.ready_file, "%d\n" % len(tunnels))
    deadline = time.monotonic() + args.max_seconds
    while not STOP.is_set():
        if time.monotonic() >= deadline:
            raise HoldFailure("held stage=hold ProbeTimeout: the hold deadline expired before a stop request")
        if CHECK.is_set():
            CHECK.clear()
            echo_round(tunnels, args.round_seconds)
            write_text(args.check_file, "%d\n" % len(tunnels))
        drain(tunnels, 0.2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--passfile", required=True)
    parser.add_argument("--count", required=True, type=int)
    parser.add_argument("--cohort", required=True)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--check-file", required=True)
    parser.add_argument("--max-seconds", type=float, default=120.0)
    parser.add_argument("--round-seconds", type=float, default=10.0)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGUSR1, request_check)
    user, password = xray_mixed.read_passfile(args.passfile)
    proxy = xray_mixed.Endpoint(args.host, args.port)
    target = xray_mixed.Endpoint(args.target_host, args.target_port)
    creds = xray_mixed.Credentials(user, password)
    tunnels = []
    try:
        # Opening is sequential, so its budget grows with the count; the round
        # that proves the tunnels shares the same deadline.
        tunnels = establish(proxy, target, creds, args.count, args.cohort,
                            args.round_seconds + 0.25 * args.count)
        hold(tunnels, args)
    finally:
        remove(args.ready_file)
        remove(args.check_file)
        close_all(tunnels)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:
        sys.stderr.write("hold-connections: %s\n" % exc)
        sys.exit(2)
