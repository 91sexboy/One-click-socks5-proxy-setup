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


class SnapshotReader:
    def __init__(self, pid, cgroup, proc_root=Path("/proc")):
        self.proc = Path(proc_root) / str(number(str(pid), "PID"))
        self.cgroup = Path(cgroup)
        self.clock_ticks = os.sysconf("SC_CLK_TCK")
        self.peak = open(self.cgroup / "memory.peak", "r+")

    def __enter__(self):
        return self

    def __exit__(self, *_error):
        self.peak.close()

    def reset(self):
        self.peak.seek(0)
        self.peak.write("0")
        self.peak.flush()
        self.peak.seek(0)

    def snapshot(self):
        status = self.proc / "status"
        stat = (self.proc / "stat").read_text().rpartition(") ")[2].split()
        if len(stat) < 13:
            raise ValueError("invalid process CPU accounting")
        ticks = number(stat[11], "utime") + number(stat[12], "stime")
        self.peak.seek(0)
        return {
            "rss_kib": field(status, "VmRSS:"),
            "rss_anon_kib": field(status, "RssAnon:"),
            "rss_file_kib": field(status, "RssFile:"),
            "rss_shmem_kib": field(status, "RssShmem:"),
            "pss_kib": field(self.proc / "smaps_rollup", "Pss:"),
            "cpu_usec": ticks * 1000000 // self.clock_ticks,
            "cgroup_current_bytes": number((self.cgroup / "memory.current").read_text(), "memory.current"),
            "cgroup_peak_bytes": number(self.peak.read(), "memory.peak"),
            "cgroup_oom": field(self.cgroup / "memory.events", "oom"),
            "cgroup_oom_kill": field(self.cgroup / "memory.events", "oom_kill"),
        }


def main():
    pid, cgroup = sys.argv[1:]
    number(pid, "PID")
    cgroup = Path(cgroup)
    print(f"kernel_release={os.uname().release}", flush=True)
    print(f"kernel_machine={os.uname().machine}", flush=True)
    active = None
    # Never reopen the peak descriptor between reset and sample: reset state is per-fd.
    with SnapshotReader(pid, cgroup) as reader:
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
                reader.reset()
                active = label
            elif action == "sample" and active == label:
                values = reader.snapshot()
                print(f"{label}_rss_kib={values['rss_kib']}")
                print(f"{label}_rss_anon_kib={values['rss_anon_kib']}")
                print(f"{label}_rss_file_kib={values['rss_file_kib']}")
                print(f"{label}_rss_shmem_kib={values['rss_shmem_kib']}")
                print(f"{label}_pss_kib={values['pss_kib']}")
                print(f"{label}_cpu_usec={values['cpu_usec']}")
                print(f"{label}_cgroup_current_bytes={values['cgroup_current_bytes']}")
                print(f"{label}_cgroup_peak_bytes={values['cgroup_peak_bytes']}")
                print(f"{label}_cgroup_oom={values['cgroup_oom']}")
                print(f"{label}_cgroup_oom_kill={values['cgroup_oom_kill']}")
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
