#!/usr/bin/env python3
"""Run the real launcher with local artifact/tool fixtures and a gated listener."""

import argparse
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
from selftest_support import TapTestCase, kill_process_group, run_tests

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests/lib"))
from release_contract import PINS

LAUNCHER = ROOT / "tests/protocol/start_engine.sh"


def wait_for(predicate, process, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        if process.poll() is not None:
            return False
        time.sleep(0.02)
    return False


def scenario(shell, marker, mode, stale=False, invalid_pass=False):
    with tempfile.TemporaryDirectory(prefix="s5ready.") as scratch:
        root = Path(scratch)
        tools = root / "bin"
        tools.mkdir()
        out = root / "out"
        out.mkdir()
        passfile = root / "pass"
        secret = "fixture_credential_do_not_replay"
        passfile.write_text("fixture_user\n" + secret + "\n", encoding="ascii")
        passfile.chmod(0o644 if invalid_pass else 0o600)
        if stale:
            for name in ("port", "ready", "ready.tmp"):
                (out / name).write_text("1\n", encoding="ascii")
        engine = root / "engine"
        engine.write_text('''#!/usr/bin/env python3
import json, os, pathlib, socket, sys, time
if "-test" in sys.argv:
    sys.exit(0)
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
(root / "started").touch()
mode = os.environ["FIXTURE_MODE"]
if mode == "exit":
    print((root / "pass").read_text().splitlines()[1], flush=True)
    print("fixture engine exited before binding", flush=True)
    sys.exit(23)
while not (root / "release").exists():
    time.sleep(0.01)
config = json.loads(pathlib.Path(sys.argv[-1]).read_text())
sock = socket.socket()
sock.bind(("127.0.0.1", config["inbounds"][0]["port"]))
sock.listen(8)
(root / "listening").touch()
while True:
    peer, _ = sock.accept()
    peer.close()
''', encoding="ascii")
        engine.chmod(0o755)
        fixture_tool = f'''#!/usr/bin/env python3
import os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
if name == "curl":
    with open(sys.argv[sys.argv.index("-o") + 1], "wb") as handle:
        handle.truncate({PINS['amd64']['size']})
elif name == "sha256sum":
    print("{PINS['amd64']['sha']}  archive")
elif name == "unzip":
    if sys.argv[1] == "-Z1":
        print("xray\\ngeoip.dat\\ngeosite.dat\\nLICENSE\\nREADME.md")
    else:
        sys.stdout.write((root / "engine").read_text())
elif name == "file":
    print("ELF 64-bit LSB executable, x86-64")
elif name == "sleep":
    time.sleep(0.01)
'''
        for name in ("curl", "sha256sum", "unzip", "file", "sleep"):
            path = tools / name
            path.write_text(fixture_tool, encoding="ascii")
            path.chmod(0o755)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                   OUTDIR=str(out), PASSFILE=str(passfile), PORT=str(port), ARCH="amd64",
                   FIXTURE_ROOT=str(root), FIXTURE_MODE=mode, REAL_PYTHON=sys.executable)
        log_path = root / "launcher.log"
        with log_path.open("w", encoding="ascii") as log:
            # BusyBox resolves built-in applets before PATH; shell functions
            # keep the same explicit tool fixtures in all four supported shells.
            wrappers = "\n".join('%s() { "$FIXTURE_ROOT/bin/%s" "$@"; }' % (name, name)
                                 for name in ("curl", "sha256sum", "unzip", "file", "sleep"))
            wrappers += '\npython3() { : >"$FIXTURE_ROOT/probed"; "$REAL_PYTHON" "$@"; }'
            command = shell + ["-c", wrappers + '\n. "$1"', "launcher-fixture", str(LAUNCHER)]
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log, start_new_session=True)
            marker_path = out / marker
            early, published, removed = False, False, False
            try:
                if invalid_pass:
                    process.wait(timeout=5)
                else:
                    if not wait_for(lambda: (root / "started").exists(), process):
                        raise AssertionError("fixture engine never started")
                    # The listener cannot bind until this test releases it. Wait
                    # for a real readiness probe, not a lucky scheduling gap.
                    if mode != "exit" and not wait_for(lambda: (root / "probed").exists(), process):
                        raise AssertionError("launcher never probed listener readiness")
                    early = marker_path.exists()
                    if mode == "healthy":
                        (root / "release").touch()
                        published = wait_for(marker_path.is_file, process)
                        if published:
                            published = ((root / "listening").exists()
                                         and marker_path.read_text().strip() == str(port))
                            if published:
                                with socket.create_connection(("127.0.0.1", port), timeout=1):
                                    pass
                    else:
                        process.wait(timeout=8)
                if mode != "healthy" or invalid_pass:
                    removed = not any((out / name).exists() for name in ("port", "ready", "ready.tmp"))
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    kill_process_group(process)
                    raise AssertionError("launcher fixture cleanup did not finish")
                # Catch leaked fixture engines even if their parent exited.
                kill_process_group(process)
        log = log_path.read_text(encoding="ascii")
        if secret in log:
            raise AssertionError("launcher diagnostics leaked the fixture credential")
        return early, published, removed, not (out / "ready").exists(), log


class LauncherTests(TapTestCase):
    shell = ["sh"]
    marker = "ready"

    def test_healthy_listener(self):
        early, published, _, cleaned, _ = scenario(self.shell, self.marker, "healthy")
        self.check("delayed listener never releases the protocol consumer early", not early)
        self.check("healthy listener publishes the consumer marker after binding", published)
        self.check("launcher shutdown removes its readiness marker", cleaned)

    def test_failed_launchers(self):
        for mode in ("exit", "never"):
            early, published, removed, _, log = scenario(self.shell, self.marker, mode, stale=True)
            self.check(mode + " cannot leave stale or false readiness", not early and not published and removed)
            self.check(mode + " has useful startup diagnostics", "before" in log or "did not become ready" in log)

    def test_preflight_failure(self):
        _, _, removed, _, _ = scenario(self.shell, self.marker, "exit", stale=True, invalid_pass=True)
        self.check("preflight failure clears stale output before validation", removed)


def main():
    global LAUNCHER
    parser = argparse.ArgumentParser()
    parser.add_argument("--shell", default="sh")
    parser.add_argument("--launcher", type=Path, default=LAUNCHER)
    args = parser.parse_args()
    LAUNCHER = args.launcher
    LauncherTests.shell = shlex.split(args.shell)
    # Follow the real consumer so an early /port publication still fails.
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    LauncherTests.marker = re.search(r'test -s "\$root/out/([^"/]+)"', workflow).group(1)
    return run_tests(unittest.defaultTestLoader.loadTestsFromTestCase(LauncherTests))


if __name__ == "__main__":
    sys.exit(main())
