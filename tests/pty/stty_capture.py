#!/usr/bin/env python3
"""PTY regression for refusing secret input without restorable termios state."""

import os
import pty
import re
import select
import signal
import sys
import termios
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(REPO, "socks5.sh")
FAILURES = []


def check(cond, desc):
    if cond:
        print("ok   - %s" % desc)
    else:
        print("not ok - %s" % desc)
        FAILURES.append(desc)


def read_until(fd, pattern, timeout=15.0):
    deadline = time.time() + timeout
    buf = b""
    rx = re.compile(pattern.encode())
    while time.time() < deadline:
        remaining = deadline - time.time()
        try:
            ready, _, _ = select.select([fd], [], [], remaining)
        except OSError:
            return buf, False
        if not ready:
            return buf, False
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            return buf, False
        if not chunk:
            return buf, False
        buf += chunk
        if rx.search(buf):
            return buf, True
    return buf, False


def echo_enabled(fd):
    try:
        return bool(termios.tcgetattr(fd)[3] & termios.ECHO)
    except termios.error:
        return None


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
        print("usage: stty_capture.py <test-root> <stub-bin-dir>")
        return 2
    root, stubbin = sys.argv[1], sys.argv[2]
    stty = os.path.join(stubbin, "stty")
    with open(stty, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n")
        fh.write("if [ \"${1:-}\" = -g ]; then exit 1; fi\n")
        fh.write("exec /bin/stty \"$@\"\n")
    os.chmod(stty, 0o700)

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

    master, slave = pty.openpty()
    pid = os.fork()
    if pid == 0:
        os.setsid()
        try:
            import fcntl
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        except Exception:
            pass
        os.dup2(slave, 0)
        os.dup2(slave, 1)
        os.dup2(slave, 2)
        os.close(master)
        os.execve("/bin/sh", ["/bin/sh", SRC, "install"], env)
        os._exit(127)

    try:
        _, ok = read_until(master, r"Select \[1-2")
        check(ok, "reached the language selector")
        os.write(master, b"2\n")
        _, ok = read_until(master, r"Continue with the installation")
        check(ok, "reached the pre-install confirmation")
        os.write(master, b"y\n")
        _, ok = read_until(master, r"SOCKS5 port")
        check(ok, "reached the port prompt")
        os.write(master, b"31080\n")
        _, ok = read_until(master, r"SOCKS5 username")
        check(ok, "reached the username prompt")
        os.write(master, b"captureuser\n")
        _, ok = read_until(master, r"SOCKS5 password")
        check(ok, "reached the password prompt")
        time.sleep(0.3)
        check(echo_enabled(slave) is True,
              "terminal echo remains enabled when termios capture fails")
        status = reap(pid)
        if os.WIFEXITED(status):
            code = os.WEXITSTATUS(status)
        elif os.WIFSIGNALED(status):
            code = 128 + os.WTERMSIG(status)
        else:
            code = -1
        check(code in (1, 130), "child refuses the password read (got %d)" % code)
        check(not os.path.exists(os.path.join(root, "var/lib/socks5-manager/state")),
              "no state file was created after termios capture failure")
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(pid, os.WNOHANG)
        except OSError:
            pass
        os.close(master)
        os.close(slave)
        try:
            os.unlink(stty)
        except OSError:
            pass

    if FAILURES:
        print("FAILED: %d check(s)" % len(FAILURES))
        return 1
    print("all stty capture checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
