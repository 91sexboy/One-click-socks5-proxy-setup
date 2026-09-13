#!/usr/bin/env python3
"""Exercise real cohort traffic without Xray, privileges, or downloads.

Only proxy connection establishment is replaced by a direct loopback connection.
The probe's framing, synchronization and cleanup, and the independent target's
reader, periodic sender and counters all execute unchanged.
"""

import concurrent.futures
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import duplex_target  # noqa: E402
import xray_mixed  # noqa: E402


def run_cohort(count, worker_limit=None, fail_connection=False):
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(256)
    listener.settimeout(0.1)
    endpoint = xray_mixed.Endpoint(*listener.getsockname())
    stopped = threading.Event()
    workers = []
    lock = threading.Lock()
    active, peak, opened = 0, 0, 0
    duplex_target.STOP.clear()
    duplex_target.ACCEPTED = 0
    duplex_target.FRAMES = 0
    duplex_target.COHORTS.clear()
    for key in xray_mixed.STATS:
        xray_mixed.STATS[key] = 0

    def worker(sock):
        nonlocal active, peak
        with lock:
            active += 1
            peak = max(peak, active)
        try:
            duplex_target.serve_connection(sock, None, None)
        finally:
            with lock:
                active -= 1

    def accept():
        while not stopped.is_set():
            try:
                sock, _ = listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            with duplex_target.COUNT_LOCK:
                duplex_target.ACCEPTED += 1
            thread = threading.Thread(target=worker, args=(sock,), daemon=True)
            workers.append(thread)
            thread.start()

    def direct(*args):
        nonlocal opened
        with lock:
            opened += 1
            if fail_connection and opened == 3:
                raise OSError("injected connection failure")
        return socket.create_connection(endpoint, timeout=3)

    pool_type = concurrent.futures.ThreadPoolExecutor

    def capped_pool(max_workers):
        return pool_type(max_workers=min(max_workers, worker_limit))

    accept_thread = threading.Thread(target=accept, daemon=True)
    accept_thread.start()
    problem = None
    background = socket.create_connection(endpoint, timeout=3)
    background.sendall(xray_mixed.make_frame(ord("H"), 500, 0, b"BACKGRND", b"hello"))
    xray_mixed.read_frame(background, time.monotonic() + 3)
    start = time.monotonic()
    try:
        with mock.patch.object(xray_mixed, "socks5_connect", direct):
            with mock.patch.object(concurrent.futures, "ThreadPoolExecutor",
                                   capped_pool if worker_limit else pool_type):
                # A deliberately short barrier budget keeps the max64 mutant
                # deterministic and bounded; the healthy 128 has ample time.
                xray_mixed.concurrency("socks5", endpoint, endpoint,
                                       xray_mixed.Credentials("u", "p"), count, timeout=3)
    except (RuntimeError, OSError, threading.BrokenBarrierError,
            xray_mixed.ProbeTimeout, xray_mixed.PeerClosed) as exc:
        problem = type(exc).__name__
    finally:
        background.close()
        stopped.set()
        listener.close()
        accept_thread.join(2)
        for thread in workers:
            thread.join(3)
    elapsed = time.monotonic() - start
    if active or accept_thread.is_alive() or any(t.is_alive() for t in workers):
        raise AssertionError("cohort left target workers or sockets alive")
    with tempfile.TemporaryDirectory(prefix="s5cohort.") as scratch:
        report_path = os.path.join(scratch, "report")
        duplex_target.write_metrics(None, report_path)
        with open(report_path, encoding="ascii") as handle:
            report = json.load(handle)
    return problem, peak, elapsed, report, dict(xray_mixed.STATS)


def gate_result(fault=None):
    """Keep matching totals while corrupting only the independent overlap proof."""
    with tempfile.TemporaryDirectory(prefix="s5cohort-gate.") as scratch:
        report = {"accepted": 161, "frames": 805, "families": [], "cohorts": {}}
        for count in (1, 32, 128):
            report["cohorts"]["cohort-%d" % count] = {
                "active": 0, "peak": count, "frame_min": count, "frames": 5 * count,
                "members": {str(1000 + i): 5 for i in range(count)},
            }
        group = report["cohorts"]["cohort-128"]
        if fault in ("peak", "frame_min"):
            group[fault] = 64
        elif fault == "members":
            group["members"]["1000"] = 4
        markers = ["mixed_target_ipv4=ok", "mixed_target_hostname=ok", "mixed_target_ipv6=unavailable",
                   "mixed_denied_control=ok", "mixed_denied_destination=ok", "mixed_denied_hostname=ok",
                   "mixed_longlived=ok", "mixed_concurrency_1=ok", "mixed_concurrency_32=ok",
                   "mixed_concurrency_128=ok"]
        if fault == "marker":
            markers.remove("mixed_concurrency_128=ok")
        stats = {"tunnels": 161, "client_frames": 805, "control_tunnels": 0, "control_frames": 0}
        probe = os.path.join(scratch, "probe.py")
        with open(probe, "w", encoding="ascii") as handle:
            handle.write("import sys\nfrom pathlib import Path\n"
                         "Path(sys.argv[sys.argv.index('--stats-file') + 1]).write_text(%r)\n"
                         "print(%r)\n" % (json.dumps(stats), "\n".join(markers)))
        report_path = os.path.join(scratch, "report")
        with open(report_path, "w", encoding="ascii") as handle:
            json.dump(report, handle)
        passfile = os.path.join(scratch, "pass")
        with open(passfile, "w", encoding="ascii") as handle:
            handle.write("fixture_user\nfixture_password\n")
        os.chmod(passfile, 0o600)
        env = dict(os.environ, PASSFILE=passfile, PORT="1", TARGET_PORT="2", REPORT=report_path,
                   OUT=os.path.join(scratch, "out"), PROBE=probe)
        gate = os.path.join(os.path.dirname(__file__), "run_xray_mixed.sh")
        return subprocess.run(["sh", gate], env=env, capture_output=True, timeout=5).returncode


def main():
    failures = 0
    checks = 0

    def check(label, ok):
        nonlocal failures, checks
        checks += 1
        print(("ok" if ok else "not ok") + " - " + label)
        failures += not ok

    for count in (1, 32, 128):
        problem, peak, _, report, stats = run_cohort(count)
        check("%d tunnels overlap while carrying valid frames" % count,
              problem is None and peak == count + 1)
        group = report.get("cohorts", {}).get("cohort-%d" % count, {})
        check("%d cohort occupancy excludes the background tunnel" % count,
              group == {"active": 0, "peak": count, "frame_min": count,
                        "frames": 5 * count, "members": {str(1000 + i): 5 for i in range(count)}})
        check("%d target/probe frame and tunnel totals reconcile" % count,
              report["accepted"] - 1 == stats["tunnels"] == count
              and report["frames"] == stats["client_frames"] == 5 * count)
    for limit in (64, 1):
        problem, peak, elapsed, _, _ = run_cohort(128, worker_limit=limit)
        check("max%d mutant rejects boundedly rather than passing batches" % limit,
              problem is not None and peak <= limit + 1 and elapsed < 10)
    problem, _, elapsed, _, _ = run_cohort(32, fail_connection=True)
    check("connection failure releases every worker and socket boundedly",
          problem is not None and elapsed < 10)
    check("gate accepts matching independent cohort observations", gate_result() == 0)
    for fault in ("peak", "frame_min", "members", "marker"):
        check("gate rejects wrong cohort %s despite matching totals" % fault, gate_result(fault) != 0)
    print("TESTS %d %d" % (checks - failures, failures))
    return int(bool(failures))


if __name__ == "__main__":
    sys.exit(main())
