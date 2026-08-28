#!/usr/bin/env python3
"""Run the credential-show path under inherited xtrace on a real PTY.

TEST-ONLY TOOLING (not a runtime dependency). The proxy password is read from
its sandboxed credential fixture; it is never passed in argv or the environment.
"""

import os
import pty
import select
import signal
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "socks5.sh")


def reap(pid, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            return status
        time.sleep(0.05)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    return os.waitpid(pid, 0)[1]


def main():
    if len(sys.argv) != 3:
        print("usage: show_xtrace.py <test-root> <stub-bin-dir>")
        return 2
    root, stubbin = sys.argv[1], sys.argv[2]

    expected_path = os.path.join(root, "expected_creds")
    try:
        with open(expected_path, "r", encoding="utf-8") as fh:
            expected = fh.read()
    except OSError as exc:
        print("show_xtrace.py: cannot read fixture: %s" % exc)
        return 1
    if ":" not in expected:
        print("show_xtrace.py: malformed credential fixture")
        return 1
    secret = expected.split(":", 1)[1]

    env = dict(os.environ)
    env.update({
        "S5_TEST_MODE": "1",
        "S5_TEST_ROOT": root,
        "S5_ASSUME_ROOT": "1",
        "S5_SKIP_OWNERSHIP": "1",
        "S5_OSRELEASE": os.path.join(REPO, "tests/fixtures/os-release/debian-12"),
        "S5_PORT_PROBE": os.path.join(stubbin, "portprobe"),
        "PATH": stubbin + os.pathsep + env.get("PATH", ""),
        "LC_ALL": "C",
    })
    env.pop("S5_LIB_ONLY", None)

    pid, master = pty.fork()
    if pid == 0:
        os.execve("/bin/sh", ["/bin/sh", "-x", SRC, "show"], env)
        os._exit(127)

    output = b""
    deadline = time.time() + 15.0
    while time.time() < deadline:
        try:
            ready, _, _ = select.select([master], [], [], 0.25)
        except OSError:
            break
        if not ready:
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done == pid:
                pid = 0
                break
            continue
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        output += chunk

    if pid:
        status = reap(pid)
    else:
        # The status was consumed only in the no-output branch above. A child that
        # exits after PTY EOF is reaped here in the common path.
        status = 0
    try:
        os.close(master)
    except OSError:
        pass

    text = output.decode("utf-8", "replace").replace("\r", "")
    trace_lines = "\n".join(line for line in text.splitlines() if line.startswith("+"))

    failures = []
    if status and (not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0):
        failures.append("show did not exit successfully")
    if secret not in text:
        failures.append("show did not display the credential on its terminal")
    if secret in trace_lines:
        failures.append("the password appeared in an xtrace line")
    if "CL:" in trace_lines:
        failures.append("credential-file content appeared in an xtrace line")
    if "refusing to display" in text:
        failures.append("show did not recognize PTY stdout as a terminal")

    if failures:
        for failure in failures:
            print("not ok - %s" % failure)
        return 1
    print("ok - terminal show succeeds and inherited xtrace reveals no secret")
    return 0


if __name__ == "__main__":
    sys.exit(main())
