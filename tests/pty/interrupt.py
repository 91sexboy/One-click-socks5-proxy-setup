#!/usr/bin/env python3
"""PTY interrupt test. TEST-ONLY TOOLING (not a runtime dependency).

Runs the real socks5.sh under a pseudo-terminal, drives it to the password
prompt, verifies that terminal echo is genuinely OFF at that moment, sends
SIGINT, and then verifies the terminal's termios has been restored with ECHO
back ON and that no state file was left behind.

Exit 0 = all checks passed. Any other exit prints the reason.
"""

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
    """Read from fd until pattern matches, returning (everything seen, matched).

    The wait is bounded by select, not just by the loop condition. os.read on a
    pty master blocks, and the deadline was only consulted between reads, so the
    timeout was unenforceable in exactly the case it exists for: a prompt that
    never appears leaves the child blocked on input while this side blocks on
    output. That deadlock used to burn the whole CI job timeout instead of
    reporting "did not reach the ... prompt".
    """
    deadline = time.time() + timeout
    buf = b""
    rx = re.compile(pattern.encode())
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return buf, False
        try:
            ready, _, _ = select.select([fd], [], [], remaining)
        except OSError:
            return buf, False
        if not ready:
            return buf, False
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if rx.search(buf):
            return buf, True
    return buf, False


def echo_enabled(fd):
    try:
        attrs = termios.tcgetattr(fd)
    except termios.error:
        return None
    return bool(attrs[3] & termios.ECHO)


def reap(pid, timeout=10.0):
    """Wait for the child, escalating to SIGKILL rather than blocking forever.

    A child that ignores SIGINT -- the very regression this file exists to catch
    -- would make a bare waitpid() hang until the CI job timeout, hiding the
    result behind an infrastructure failure. Escalating makes the same defect
    surface as a reported check.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done == pid:
            return status
        time.sleep(0.05)
    sys.stderr.write("interrupt.py: child %d did not exit after SIGINT; "
                     "escalating to SIGKILL\n" % pid)
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    return os.waitpid(pid, 0)[1]


def main():
    if len(sys.argv) < 3:
        print("usage: interrupt.py <test-root> <stub-bin-dir>")
        return 2
    root, stubbin = sys.argv[1], sys.argv[2]

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
    baseline = echo_enabled(slave)
    check(baseline is True, "baseline: the pty has ECHO enabled before we start")

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

    # The parent deliberately keeps `slave` open: echo_enabled(slave) is queried
    # again after the child exits, which needs a live fd on the same terminal.

    # Drive: acknowledge the warning, choose a port and a username.
    _, ok = read_until(master, r"Continue with the installation")
    check(ok, "reached the pre-install confirmation")
    os.write(master, b"y\n")
    _, ok = read_until(master, r"SOCKS5 port")
    check(ok, "reached the port prompt")
    os.write(master, b"31080\n")
    _, ok = read_until(master, r"SOCKS5 username")
    check(ok, "reached the username prompt")
    os.write(master, b"ptyuser\n")
    _, ok = read_until(master, r"SOCKS5 password")
    check(ok, "reached the password prompt")

    # Give the shell a moment to apply stty -echo, then confirm echo really is off.
    time.sleep(0.4)
    check(echo_enabled(slave) is False,
          "terminal echo is DISABLED while the password is being read")

    # Interrupt exactly here.
    os.kill(pid, signal.SIGINT)
    status = reap(pid)

    time.sleep(0.3)
    check(echo_enabled(slave) is True,
          "terminal echo is RESTORED after SIGINT at the password prompt")

    if os.WIFEXITED(status):
        code = os.WEXITSTATUS(status)
    elif os.WIFSIGNALED(status):
        code = 128 + os.WTERMSIG(status)
    else:
        code = -1
    check(code in (130, 1), "child exited with an interrupt status (got %d)" % code)

    statefile = os.path.join(root, "var/lib/socks5-manager/state")
    check(not os.path.exists(statefile),
          "no state file was left behind (interrupt happened before any was created)")

    builds = os.path.join(root, "build")
    leftover = []
    if os.path.isdir(builds):
        leftover = [d for d in os.listdir(builds) if d.startswith("b.")]
    check(not leftover, "no build directory was left behind: %r" % (leftover,))

    os.close(master)
    if FAILURES:
        print("FAILED: %d check(s)" % len(FAILURES))
        return 1
    print("all pty checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
