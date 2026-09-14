#!/usr/bin/env python3
"""CI-only root experiment: a releasable high workload then a much lower one.

Uses its own cgroup; neither sampler nor driver enters the workload cgroup.
Never called by local unit tests. Unsupported interfaces fail, not report zero.
"""
import mmap
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time


MIB = 1024 * 1024


def reply(process, expected):
    deadline = time.monotonic() + 10
    lines = []
    line = b""
    while time.monotonic() < deadline:
        if not select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))[0]:
            break
        char = os.read(process.stdout.fileno(), 1)
        if not char:
            raise RuntimeError("experiment child exited before acknowledgement")
        line += char
        if char == b"\n":
            text = line.decode().strip()
            lines.append(text)
            line = b""
            if text == expected:
                return lines
    raise TimeoutError("experiment acknowledgement timed out")


def command(process, text, expected):
    process.stdin.write((text + "\n").encode())
    process.stdin.flush()
    return reply(process, expected)


def stop(process):
    if process is None:
        return
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def worker(cgroup):
    (cgroup / "cgroup.procs").write_text(str(os.getpid()))
    memory = None
    print("ready", flush=True)
    for line in sys.stdin:
        size = int(line)
        if memory is not None:
            memory.close()
            memory = None
        if size:
            memory = mmap.mmap(-1, size * MIB)
            for offset in range(0, size * MIB, mmap.PAGESIZE):
                memory[offset] = 1
        print("allocated", flush=True)


def experiment():
    cgroup = Path(f"/sys/fs/cgroup/s5-memory-peak-check-{os.getpid()}")
    target = sampler = None
    cgroup.mkdir()
    try:
        target = subprocess.Popen([sys.executable, __file__, "--worker", str(cgroup)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        reply(target, "ready")
        baseline = int((cgroup / "memory.current").read_text())
        sampler = subprocess.Popen(["sh", str(Path(__file__).with_name("memory-sample.sh")),
                                    str(target.pid), str(cgroup)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        values = {}
        print("peak_check_workload=anonymous_mmap_touch_every_page_release_between_stages")
        print("peak_check_high_mib=128\npeak_check_low_mib=8")
        print(f"peak_check_baseline_bytes={baseline}")
        for label, size in (("check_high", 128), ("check_low", 8)):
            command(target, "0", "allocated")
            deadline = time.monotonic() + 5
            while int((cgroup / "memory.current").read_text()) > baseline + 16 * MIB:
                if time.monotonic() >= deadline:
                    raise RuntimeError("high workload memory did not release")
                time.sleep(0.05)
            lines = command(sampler, f"reset {label}", f"{label}_reset=ok")
            command(target, str(size), "allocated")
            lines += command(sampler, f"sample {label}", f"{label}_sample=ok")
            for line in lines:
                print(line)
                if "=" in line:
                    key, value = line.split("=", 1)
                    values[key] = value
        high = int(values["check_high_cgroup_peak_bytes"])
        low = int(values["check_low_cgroup_peak_bytes"])
        lifetime = int((cgroup / "memory.peak").read_text())
        print(f"peak_check_lifetime_peak_bytes={lifetime}")
        if not (high >= 128 * MIB and low + 64 * MIB < high and low + 64 * MIB < lifetime):
            raise RuntimeError("low stage did not exclude the prior high-water mark")
        sampler.stdin.write(b"quit\n")
        sampler.stdin.flush()
        if sampler.wait(timeout=5) != 0:
            raise RuntimeError("sampler failed")
        print("peak_check_high_then_low=ok")
    finally:
        stop(sampler)
        stop(target)
        for attempt in range(30):
            try:
                cgroup.rmdir()
                break
            except OSError:
                if attempt == 29:
                    raise
                time.sleep(0.1)


if __name__ == "__main__":
    try:
        if os.environ.get("GITHUB_ACTIONS") != "true" or os.geteuid() != 0:
            raise RuntimeError("native peak experiments run only as root in disposable GitHub Actions environments")
        if len(sys.argv) == 3 and sys.argv[1] == "--worker":
            worker(Path(sys.argv[2]))
        elif sys.argv[1:] == ["--real-cgroup"]:
            def interrupted(signum, _frame):
                # Unwind experiment's finally block instead of orphaning workers.
                raise SystemExit(128 + signum)
            for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
                signal.signal(signum, interrupted)
            experiment()
        else:
            raise ValueError("CI root experiment requires --real-cgroup")
    except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.TimeoutExpired) as error:
        print(f"memory peak experiment unavailable/failed: {error}", file=sys.stderr)
        sys.exit(1)
