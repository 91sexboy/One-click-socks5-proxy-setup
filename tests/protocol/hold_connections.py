#!/usr/bin/env python3
"""Hold N authenticated tunnels open so memory can be sampled under load.

SPEC 8 wants separate idle/1/32/128-connection peaks. Sampling a service that
has no connections open measures only the idle case, so the load has to be held
still while the sampler reads the cgroup.
"""

import argparse
import signal
import sys
import threading

from duplex_target import write_text
import xray_mixed

STOP = threading.Event()


def stop(signum, frame_info):
    STOP.set()


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
            socks.append(sock)
            cid = 5000 + index
            nonce = xray_mixed.new_nonce()
            sock.sendall(xray_mixed.make_frame(xray_mixed.FRAME_HELLO, cid, 0, nonce, b"hello"))
        write_text(args.ready_file, "%d\n" % len(socks))
        STOP.wait(args.max_seconds)
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
