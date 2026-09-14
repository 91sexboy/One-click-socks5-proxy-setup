#!/usr/bin/env python3
"""Nonprivileged behavior checks for the lifecycle gate's owned-child cleanup."""
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SHELL = shlex.split(os.environ.get("S5_TEST_SHELL", "sh"))
HELPER = ROOT / ".github/scripts/lifecycle-target.sh"
SCENARIOS = ("normal", "error", "TERM", "HUP", "INT", "exited", "unstarted", "stubborn", "repeated",
             "namespace_failure", "namespace_primary_error", "removal_failure")


def eventually(predicate, message, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError(message)


def check_cleanup(case, mode):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        work = root / "work"
        work.mkdir()
        target = root / "target.py"
        target.write_text('''import os, signal, socket, sys, time
from pathlib import Path
work, mode = Path(sys.argv[1]), sys.argv[2]
sock = socket.socket()
sock.bind(("127.0.0.1", 0)); sock.listen()
def stop(*args):
    (work.parent / "stopped-before-removal").write_text(str(work.is_dir()))
    sys.exit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN if mode == "stubborn" else stop)
(work.parent / "ready.tmp").write_text(f"{os.getpid()} {sock.getsockname()[1]}")
(work.parent / "ready.tmp").replace(work.parent / "ready")
while True: time.sleep(0.05)
''')
        script = root / "driver.sh"
        script.write_text('''set -eu
. "$1"
work=$2
mode=$3
# Replace only privileged namespace teardown, keeping actual child and workdir cleanup.
lifecycle_cleanup_namespace() {
    case "$mode" in namespace_failure | namespace_primary_error) return 23 ;; esac
}
if [ "$mode" = removal_failure ]; then rm() { return 29; }; fi
lifecycle_cleanup_init
if [ "$3" = unstarted ]; then exit 19; fi
python3 "$4" "$work" "$3" >"$work/target.log" 2>&1 &
target_pid=$!
while [ ! -s "$work/../ready" ]; do sleep 0.02; done
if [ "$3" = exited ]; then kill "$target_pid"; wait "$target_pid" || true; fi
printf ready >"$work/../driver-ready"
case "$3" in
    normal | exited | stubborn | namespace_failure | removal_failure) exit 0 ;;
    repeated) lifecycle_cleanup; lifecycle_cleanup; exit 0 ;;
    error | namespace_primary_error) exit 37 ;;
    *) while :; do sleep 0.05; done ;;
esac
''')
        proc = subprocess.Popen(SHELL + [str(script), str(HELPER), str(work), mode, str(target)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        pid = None
        try:
            if mode != "unstarted":
                eventually(lambda: (root / "ready").exists() or proc.poll() is not None,
                           "target never started")
                case.assertTrue((root / "ready").exists(), "cleanup driver failed before target startup")
                pid, port = map(int, (root / "ready").read_text().split())
                if mode in ("TERM", "HUP", "INT"):
                    eventually(lambda: (root / "driver-ready").exists(), "driver not ready")
                    proc.send_signal(getattr(signal, "SIG" + mode))
            stdout, stderr = proc.communicate(timeout=8)
            expected = {"error": 37, "unstarted": 19, "TERM": 143, "HUP": 129, "INT": 130,
                        "namespace_failure": 23, "namespace_primary_error": 37, "removal_failure": 29}.get(mode, 0)
            case.assertEqual(proc.returncode, expected, f"{mode}: unexpected cleanup status")
            case.assertEqual(work.exists(), mode == "removal_failure", f"{mode}: unexpected final workdir state")
            if mode in ("namespace_failure", "namespace_primary_error", "removal_failure"):
                case.assertIn(b"cleanup failed", stderr, f"{mode}: cleanup failure was not diagnosed")
            if pid:
                case.assertFalse(Path(f"/proc/{pid}").exists(), f"{mode}: target remains alive or unreaped")
                with socket.socket() as probe:
                    case.assertNotEqual(probe.connect_ex(("127.0.0.1", port)), 0, f"{mode}: target listener remains")
                if mode != "stubborn":
                    case.assertEqual((root / "stopped-before-removal").read_text(), "True", "workdir removed before stop")
        finally:
            if proc.poll() is None:
                proc.kill()
            if pid and Path(f"/proc/{pid}").exists():
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.communicate(timeout=3)


class CleanupTests(unittest.TestCase):
    def test_owned_child_lifecycle(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
        try:
            for scenario in SCENARIOS:
                with self.subTest(scenario=scenario):
                    check_cleanup(self, scenario)
                    self.assertIsNone(unrelated.poll(), "cleanup killed an unrelated process")
        finally:
            unrelated.terminate()
            unrelated.wait(timeout=3)


def main():
    global HELPER
    if len(sys.argv) > 1:
        HELPER = Path(sys.argv[1]) / ".github/scripts/lifecycle-target.sh"
    result = unittest.TextTestRunner().run(unittest.defaultTestLoader.loadTestsFromTestCase(CleanupTests))
    if result.wasSuccessful():
        print("lifecycle owned-child cleanup: %d scenarios passed; unrelated process preserved" % len(SCENARIOS))
    return int(not result.wasSuccessful())


if __name__ == "__main__":
    sys.exit(main())
