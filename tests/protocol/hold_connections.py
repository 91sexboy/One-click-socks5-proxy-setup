#!/usr/bin/env python3
"""Hold N authenticated tunnels open so memory can be sampled under load.

SPEC 8 wants separate idle/1/32/128-connection peaks. Sampling a service that
has no connections open measures only the idle case, so the load has to be held
still while the sampler reads the cgroup.
"""

import argparse
import signal
import struct
import sys
import time

import xray_mixed

STOP = False


def stop(signum, frame_info):
    global STOP
    STOP = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--passfile", required=True)
    parser.add_argument("--count", required=True, type=int)
    parser.add_argument("--ready-file", required=True)
    parser.add_argument("--max-seconds", type=float, default=120.0)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    user, password = xray_mixed.read_passfile(args.passfile)
    proxy = xray_mixed.Endpoint(args.host, args.port)
    target = xray_mixed.Endpoint(args.target_host, args.target_port)
    creds = xray_mixed.Credentials(user, password)
    socks = []
    try:
        for index in range(args.count):
            sock = xray_mixed.socks5_connect(proxy, target, creds, "ipv4")
            cid = 5000 + index
            nonce = struct.pack("!Q", cid * 104729 + 17)
            sock.sendall(xray_mixed.make_frame(ord("H"), cid, 0, nonce, b"hello"))
            socks.append(sock)
        with open(args.ready_file, "w", encoding="ascii") as handle:
            handle.write("%d\n" % len(socks))
        deadline = time.monotonic() + args.max_seconds
        while not STOP and time.monotonic() < deadline:
            time.sleep(0.2)
    finally:
        for sock in socks:
            try:
                sock.close()
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException as exc:
        sys.stderr.write("hold-connections: %s\n" % exc)
        sys.exit(2)
