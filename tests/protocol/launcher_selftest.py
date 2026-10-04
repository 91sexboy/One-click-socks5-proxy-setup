#!/usr/bin/env python3
"""Run the real launcher with local artifact/tool fixtures and a gated listener."""

import argparse
import base64
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
from release_contract import RAW_ASSETS

DEFAULT_LAUNCHER = ROOT / "tests/protocol/start_engine.sh"


def wait_for(predicate, process, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        if process.poll() is not None:
            return False
        time.sleep(0.02)
    return False


TOOLS = ("curl", "sha256sum", "file", "sleep")
# Text tools the shared redactor runs; their argv is recorded to prove no
# credential form is ever handed to an external command.
TEXT_TOOLS = ("awk", "sed", "tr", "base64", "grep", "cat")
USER = "fixture_user"
SECRET = "fixture_credential_do_not_replay"
PAIR = USER + ":" + SECRET
# Every form a log can carry the credential in: password, user:pass, base64.
FORMS = (SECRET, PAIR, base64.b64encode(PAIR.encode("ascii")).decode("ascii"))
REDACTED_LINE = "fixture diagnostic password=<REDACTED> pair=<REDACTED> basic=<REDACTED> end"
LIFECYCLE_COMMON = ROOT / ".github/scripts/lifecycle-common.sh"
ENGINE = '''#!/usr/bin/env python3
import json, os, pathlib, socket, sys, time
if sys.argv[1:] == ["version"]:
    print("Xray 26.3.27 (synthetic launcher fixture)")
    sys.exit(0)
if "-test" in sys.argv:
    sys.exit(0)
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
(root / "started").touch()
mode = os.environ["FIXTURE_MODE"]
if mode.startswith("exit"):
    user, password = (root / "pass").read_text().splitlines()[:2]
    pair = user + ":" + password
    encoded = __import__("base64").b64encode(pair.encode()).decode()
    if mode == "exit-lost-passfile":
        (root / "pass").unlink()
    elif mode == "exit-rotated-passfile":
        (root / "pass").write_text("rotated_user\\nrotated_credential\\n")
    # One error line carries every credential form between ordinary text.
    print("fixture diagnostic password=%s pair=%s basic=%s end" % (password, pair, encoded), flush=True)
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
'''
FIXTURE_TOOL = f'''#!/usr/bin/env python3
import os, pathlib, sys, time
name = pathlib.Path(sys.argv[0]).name
root = pathlib.Path(os.environ["FIXTURE_ROOT"])
if name == "curl":
    target = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
    body = (root / "engine").read_text()
    target.write_text(body + "#" + "x" * ({RAW_ASSETS['amd64'][1]} - len(body) - 2) + "\\n")
elif name == "sha256sum":
    target = pathlib.Path(sys.argv[-1])
    print("{RAW_ASSETS['amd64'][2]}  " + target.name)
elif name == "file":
    print("ELF 64-bit LSB executable, x86-64, statically linked")
elif name == "sleep":
    time.sleep(0.01)
'''


def write_fixtures(root, stale, invalid_pass):
    """Lay out the fixture engine, tools, password file and output directory."""
    tools = root / "bin"
    tools.mkdir()
    out = root / "out"
    out.mkdir()
    passfile = root / "pass"
    passfile.write_text(USER + "\n" + SECRET + "\n", encoding="ascii")
    passfile.chmod(0o644 if invalid_pass else 0o600)
    if stale:
        for name in ("port", "ready", "ready.tmp"):
            (out / name).write_text("1\n", encoding="ascii")
    engine = root / "engine"
    engine.write_text(ENGINE, encoding="ascii")
    engine.chmod(0o755)
    for name in TOOLS:
        path = tools / name
        path.write_text(FIXTURE_TOOL, encoding="ascii")
        path.chmod(0o755)
    return tools, out, passfile


def free_port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


def fixture_wrappers():
    # BusyBox resolves built-in applets before PATH; shell functions keep the
    # same explicit tool fixtures in all four supported shells.
    wrappers = "\n".join('%s() { "$FIXTURE_ROOT/bin/%s" "$@"; }' % (name, name) for name in TOOLS)
    # Replace only the launcher transport and verification command seams.
    wrappers += '\ncurl_command() { "$FIXTURE_ROOT/bin/curl" "$@"; }'
    wrappers += '\nsha256_command() { "$FIXTURE_ROOT/bin/sha256sum" "$@"; }'
    wrappers += '\nfile_type_command() { "$FIXTURE_ROOT/bin/file" -b "$@"; }'
    wrappers += '\npython3() { : >"$FIXTURE_ROOT/probed"; "$REAL_PYTHON" "$@"; }'
    wrappers += "".join('\n%s() { printf "%%s\\n" "$@" >>"$FIXTURE_ROOT/argv"; command %s "$@"; }'
                        % (name, name) for name in TEXT_TOOLS)
    return wrappers


def observe(process, root, out, marker, mode, port, invalid_pass):
    """Drive one launch to its end; return (early, published, removed)."""
    marker_path = out / marker
    early, published, removed = False, False, False
    if invalid_pass:
        process.wait(timeout=5)
    else:
        if not wait_for(lambda: (root / "started").exists(), process):
            raise AssertionError("fixture engine never started")
        # The listener cannot bind until this test releases it. Wait for a real
        # readiness probe, not a lucky scheduling gap.
        if not mode.startswith("exit") and not wait_for(lambda: (root / "probed").exists(), process):
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
    return early, published, removed


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        kill_process_group(process)
        raise AssertionError("launcher fixture cleanup did not finish")
    # Catch leaked fixture engines even if their parent exited.
    kill_process_group(process)


class Launch:
    """What one launch left behind, read before its scratch tree is removed."""

    def __init__(self, early, published, removed, cleaned, log, argv, leftovers):
        self.early, self.published, self.removed, self.cleaned = early, published, removed, cleaned
        self.log, self.argv, self.leftovers = log, argv, leftovers


def leaked(text):
    return any(form in text for form in FORMS)


def scenario(launcher, shell, marker, mode, stale=False, invalid_pass=False):
    with tempfile.TemporaryDirectory(prefix="s5ready.") as scratch:
        root = Path(scratch)
        tools, out, passfile = write_fixtures(root, stale, invalid_pass)
        private = root / "tmp"
        private.mkdir()
        port = free_port()
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                   OUTDIR=str(out), PASSFILE=str(passfile), PORT=str(port), ARCH="amd64",
                   FIXTURE_ROOT=str(root), FIXTURE_MODE=mode, REAL_PYTHON=sys.executable,
                   TMPDIR=str(private))
        # A relocated launcher (a mutation copy) cannot find the shared redactor
        # beside itself in the checkout; the real one must, so it gets no hint.
        if Path(launcher).resolve() != DEFAULT_LAUNCHER:
            env["LIFECYCLE_COMMON"] = str(LIFECYCLE_COMMON)
        log_path = root / "launcher.log"
        with log_path.open("w", encoding="ascii") as log:
            # $0 is the launcher path, as it is when CI runs "sh start_engine.sh".
            command = shell + ["-c", fixture_wrappers() + '\n. "$0"', str(launcher)]
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log, start_new_session=True)
            try:
                early, published, removed = observe(process, root, out, marker, mode, port, invalid_pass)
            finally:
                stop(process)
        log = log_path.read_text(encoding="ascii")
        if leaked(log):
            raise AssertionError("launcher diagnostics leaked the fixture credential")
        argv_path = root / "argv"
        argv = argv_path.read_text(encoding="ascii") if argv_path.exists() else ""
        return Launch(early, published, removed, not (out / "ready").exists(), log, argv,
                      sorted(entry.name for entry in private.iterdir()))


def outer_ci_redaction(shell, log):
    """Re-filter a launcher log the way the CI step does, with its own patterns."""
    with tempfile.TemporaryDirectory(prefix="s5outer.") as scratch:
        root = Path(scratch)
        passfile = root / "pass"
        passfile.write_text(USER + "\n" + SECRET + "\n", encoding="ascii")
        passfile.chmod(0o600)
        (root / "engine.log").write_text(log, encoding="ascii")
        script = ('. "$1" && lifecycle_redaction_file "$2/redact.pat" "$2/pass" && '
                  'lifecycle_redact "$2/redact.pat" <"$2/engine.log"')
        result = subprocess.run(shell + ["-c", script, "outer-ci", str(LIFECYCLE_COMMON), str(root)],
                                capture_output=True, text=True, timeout=10)
        return result.returncode, result.stdout


class LauncherTests(TapTestCase):
    launcher = DEFAULT_LAUNCHER
    shell = ["sh"]
    marker = "ready"

    def test_healthy_listener(self):
        launch = scenario(self.launcher, self.shell, self.marker, "healthy")
        self.check("delayed listener never releases the protocol consumer early", not launch.early)
        self.check("healthy listener publishes the consumer marker after binding", launch.published)
        self.check("launcher shutdown removes its readiness marker", launch.cleaned)

    def test_failed_launchers(self):
        for mode in ("exit", "never"):
            launch = scenario(self.launcher, self.shell, self.marker, mode, stale=True)
            self.check(mode + " cannot leave stale or false readiness",
                       not launch.early and not launch.published and launch.removed)
            self.check(mode + " has useful startup diagnostics",
                       "before" in launch.log or "did not become ready" in launch.log)

    def test_preflight_failure(self):
        launch = scenario(self.launcher, self.shell, self.marker, "exit", stale=True, invalid_pass=True)
        self.check("preflight failure clears stale output before validation", launch.removed)

    def test_engine_log_is_redacted_in_place(self):
        launch = scenario(self.launcher, self.shell, self.marker, "exit")
        lines = launch.log.splitlines()
        self.check("the credential-bearing engine line survives with every form replaced", REDACTED_LINE in lines)
        self.check("ordinary engine diagnostics survive redaction", "fixture engine exited before binding" in lines)
        self.check("the launcher's own failure reason survives redaction",
                   "xray launcher: Xray exited before the listener became ready" in lines)
        self.check("the redactor's text tools were observed", launch.argv != "")
        self.check("redaction keeps every credential form out of command argv", not leaked(launch.argv))
        self.check("redaction leaves no private pattern or work file behind", launch.leftovers == [])

    def test_outer_ci_redaction_keeps_diagnostics(self):
        launch = scenario(self.launcher, self.shell, self.marker, "exit")
        status, nested = outer_ci_redaction(self.shell, launch.log)
        self.check("the CI outer redactor accepts the standalone launcher log", status == 0)
        self.check("re-redacting a standalone launcher log changes and drops nothing", nested == launch.log)

    def test_unrebuildable_patterns_withhold_engine_log(self):
        for mode in ("exit-lost-passfile", "exit-rotated-passfile"):
            launch = scenario(self.launcher, self.shell, self.marker, mode)
            self.check(mode + " withholds the raw engine log", "fixture diagnostic" not in launch.log
                       and "fixture engine exited" not in launch.log)
            self.check(mode + " says why the engine log is withheld", "engine log withheld" in launch.log)
            self.check(mode + " keeps the launcher's own failure reason",
                       "Xray exited before the listener became ready" in launch.log)
            self.check(mode + " leaves no private pattern or work file behind", launch.leftovers == [])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shell", default="sh")
    parser.add_argument("--launcher", type=Path, default=DEFAULT_LAUNCHER)
    args = parser.parse_args()
    LauncherTests.launcher = args.launcher
    LauncherTests.shell = shlex.split(args.shell)
    # Follow the real consumer so an early /port publication still fails.
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    LauncherTests.marker = re.search(r'test -s "\$root/out/([^"/]+)"', workflow).group(1)
    return run_tests(unittest.defaultTestLoader.loadTestsFromTestCase(LauncherTests))


if __name__ == "__main__":
    sys.exit(main())
