#!/usr/bin/env python3
"""Persistent memory-report sampler. Commands on stdin: reset LABEL, sample LABEL, quit.

A reset acknowledgement precedes workload creation; a sample acknowledgement
follows all metrics. One read/write memory.peak descriptor belongs to the entire
session. RSS is a process snapshot, current is cgroup usage, peak is stage-local;
OOM counters are cumulative. None of these measures listener readiness.
"""
import os
from pathlib import Path
import re
import select
import sys


def number(text, name):
    text = text.strip()
    if not text.isdecimal():
        raise ValueError(f"invalid {name}")
    return int(text)


def field(path, key):
    for line in path.read_text().splitlines():
        parts = line.split()
        if parts and parts[0] == key:
            if len(parts) < 2:
                raise ValueError(f"missing value for {key}")
            return number(parts[1], key)
    raise ValueError(f"missing {key}")


def main():
    pid, cgroup = sys.argv[1:]
    number(pid, "PID")
    cgroup = Path(cgroup)
    print(f"kernel_release={os.uname().release}", flush=True)
    print(f"kernel_machine={os.uname().machine}", flush=True)
    active = None
    # Never reopen this file between reset and sample: reset state is per-fd.
    peak = open(cgroup / "memory.peak", "r+")
    while True:
        if not select.select([sys.stdin], [], [], 60)[0]:
            raise TimeoutError("sampler command timeout")
        line = sys.stdin.readline()
        if not line or line.strip() == "quit":
            return
        action, label = line.split()
        if not re.fullmatch(r"[A-Za-z0-9_]+", label):
            raise ValueError("invalid stage label")
        if action == "reset":
            peak.seek(0)
            peak.write("0")
            peak.flush()
            peak.seek(0)
            active = label
        elif action == "sample" and active == label:
            rss = field(Path(f"/proc/{pid}/status"), "VmRSS:")
            current = number((cgroup / "memory.current").read_text(), "memory.current")
            peak.seek(0)
            stage_peak = number(peak.read(), "memory.peak")
            oom = field(cgroup / "memory.events", "oom")
            oom_kill = field(cgroup / "memory.events", "oom_kill")
            print(f"{label}_rss_kib={rss}")
            print(f"{label}_cgroup_current_bytes={current}")
            print(f"{label}_cgroup_peak_bytes={stage_peak}")
            print(f"{label}_cgroup_oom={oom}")
            print(f"{label}_cgroup_oom_kill={oom_kill}")
            active = None
        else:
            raise ValueError("sample requires a matching reset")
        print(f"{label}_{action}=ok", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TimeoutError) as error:
        print(f"memory sampler unavailable: {error}", file=sys.stderr)
        sys.exit(1)
