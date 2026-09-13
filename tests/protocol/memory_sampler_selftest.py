#!/usr/bin/env python3
"""Exercise the sampler process with a descriptor-local memory.peak interface.

The fake device preserves the kernel's important semantic: only the descriptor
written to sees a reset. Reopening always sees the lifetime high-water mark.
No real cgroup or privileged operation is used here.
"""
from pathlib import Path
import importlib.util
import subprocess
import sys
import tempfile
from unittest import mock

sys.dont_write_bytecode = True

ROOT = Path(sys.argv[1])
HELPER = ROOT / ".github/scripts/memory-sampler.py"


def check(reset_supported=True):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "memory.current").write_text("100\n")
        (root / "memory.events").write_text("oom 0\noom_kill 0\n")
        bootstrap = root / "bootstrap.py"
        bootstrap.write_text('''import builtins, io, runpy, sys
from pathlib import Path
helper, cgroup, supported = sys.argv[1:]
original_open = builtins.open
class Device(io.StringIO):
    def __init__(self):
        super().__init__()
        self.baseline = 800
    def write(self, value):
        if supported == "no": raise OSError("reset unsupported")
        self.baseline = int(Path(cgroup, "memory.current").read_text())
        return len(value)
    def read(self, *args):
        return str(max(self.baseline, int(Path(cgroup, "memory.current").read_text())))
def device_open(path, mode="r", *args, **kwargs):
    if str(path) == str(Path(cgroup, "memory.peak")):
        if mode != "r+": raise OSError("memory.peak needs a read/write descriptor")
        return Device()
    return original_open(path, mode, *args, **kwargs)
builtins.open = device_open
sys.argv = [helper, str(__import__("os").getpid()), cgroup]
runpy.run_path(helper, run_name="__main__")
''')
        proc = subprocess.Popen([sys.executable, str(bootstrap), str(HELPER), str(root),
                                 "yes" if reset_supported else "no"],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        output = []

        def command(action, label):
            proc.stdin.write(f"{action} {label}\n")
            proc.stdin.flush()
            while True:
                # Process-level timeout bounds even a broken sampler's reply.
                import select
                # TextIO may prefetch lines; read one character stream below instead.
                line = ""
                while not line.endswith("\n"):
                    ready, _, _ = select.select([proc.stdout], [], [], 3)
                    assert ready, "sampler reply timed out"
                    char = __import__("os").read(proc.stdout.fileno(), 1).decode()
                    assert char, "sampler exited before acknowledging stage"
                    line += char
                output.append(line.strip())
                if line.strip() == f"{label}_{action}=ok":
                    return

        try:
            if not reset_supported:
                stdout, stderr = proc.communicate("reset low\nsample low\nquit\n", timeout=5)
                assert proc.returncode != 0, "unsupported reset must fail"
                assert "unavailable" in stderr, "unsupported reset needs explicit unavailable diagnostic"
                assert "low_cgroup_peak_bytes=" not in stdout, "unsupported reset fabricated a stage peak"
                return
            command("reset", "high")
            (root / "memory.current").write_text("800\n")
            command("sample", "high")
            (root / "memory.current").write_text("100\n")
            command("reset", "low")
            (root / "memory.current").write_text("200\n")
            command("sample", "low")
            stdout, stderr = proc.communicate("quit\n", timeout=5)
            assert proc.returncode == 0, "valid sample session failed"
            values = dict(line.split("=", 1) for line in output if "=" in line)
            assert values["high_cgroup_peak_bytes"] == "800", "high peak is not descriptor-local"
            assert values["low_cgroup_peak_bytes"] == "200", "low peak retained the lifetime high"
            assert values["low_cgroup_current_bytes"] == "200"
            assert int(values["low_rss_kib"]) > 0
            assert values["low_cgroup_oom"] == "0" and values["low_cgroup_oom_kill"] == "0"
            assert values["kernel_release"] == __import__("os").uname().release
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.communicate(timeout=3)


def check_snapshot():
    spec = importlib.util.spec_from_file_location("memory_sampler", HELPER)
    sampler = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(sampler)
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        proc = root / "proc" / "123"
        proc.mkdir(parents=True)
        status = "VmRSS: 40 kB\nRssAnon: 12 kB\nRssFile: 24 kB\nRssShmem: 4 kB\n"
        (proc / "status").write_text(status)
        (proc / "smaps_rollup").write_text("Pss: 20 kB\n")
        fields = ["S"] + ["0"] * 49
        fields[11], fields[12] = "7", "3"
        (proc / "stat").write_text("123 (worker (test)) " + " ".join(fields))
        (root / "memory.current").write_text("40960\n")
        (root / "memory.peak").write_text("49152\n")
        (root / "memory.events").write_text("oom 0\noom_kill 0\n")
        with mock.patch.object(sampler.os, "sysconf", return_value=100):
            with sampler.SnapshotReader(123, root, proc_root=root / "proc") as reader:
                assert reader.snapshot() == {
                    "rss_kib": 40, "rss_anon_kib": 12, "rss_file_kib": 24,
                    "rss_shmem_kib": 4, "pss_kib": 20, "cpu_usec": 100000,
                    "cgroup_current_bytes": 40960, "cgroup_peak_bytes": 49152,
                    "cgroup_oom": 0, "cgroup_oom_kill": 0,
                }, "snapshot mixed accounting units or parsed CPU comm incorrectly"
                (proc / "status").write_text(status.replace("RssAnon: 12 kB\n", ""))
                try:
                    reader.snapshot()
                except ValueError:
                    pass
                else:
                    raise AssertionError("missing RSS accounting was silently accepted")


check_snapshot()
check()
check(reset_supported=False)
print("persistent memory sampler: snapshot, high/low and unsupported-reset scenarios passed")
