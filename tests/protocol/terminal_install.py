#!/usr/bin/env python3
"""Verify a real install's terminal output without publishing its credentials."""

import errno
import os
import select
import signal
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from selftest_support import PtySession, kill_process_group


class TerminalFailure(Exception):
    def __init__(self, message, output=b""):
        super().__init__(message)
        self.output = output


def capture_terminal(command, answers, timeout=600):
    process = None
    output = bytearray()
    deadline = time.monotonic() + timeout
    try:
        with PtySession() as terminal:
            with open(answers, "rb") as source:
                environment = dict(os.environ, S5_SERVER_IPV4="192.0.2.1")
                # File-fed answers cannot manufacture a credential card through terminal echo.
                process = subprocess.Popen(
                    command, stdin=source, stdout=terminal.slave, stderr=terminal.slave,
                    env=environment, start_new_session=True,
                )
            terminal.close_slave()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TerminalFailure("terminal install timed out")
                ready, _, _ = select.select([terminal.master], [], [], min(remaining, 1))
                if not ready:
                    continue
                try:
                    chunk = os.read(terminal.master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
                if not chunk:
                    break
                output.extend(chunk)
                if len(output) > 8 * 1024 * 1024:
                    raise TerminalFailure("terminal install exceeded the output limit")
            try:
                status = process.wait(timeout=max(0.1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                raise TerminalFailure("terminal install timed out") from None
            if status != 0:
                raise TerminalFailure("terminal install exited with status %d" % status)
            return bytes(output)
    except TerminalFailure as error:
        error.output = bytes(output)
        raise
    finally:
        if process is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                kill_process_group(process)


def verify_card(output, username, password, port, prompts):
    if output.count(b"Choose language") != prompts:
        raise TerminalFailure("unexpected language prompt count")
    endpoint = "%s:%s@192.0.2.1:%s" % (username, password, port)
    for scheme in ("socks5", "http"):
        uri = (scheme + "://" + endpoint).encode("utf-8")
        if output.count(uri) != 1:
            raise TerminalFailure("expected exactly one %s credential URI" % scheme)


def report_failure(output, passfile, password):
    secret = password.encode("utf-8")
    with tempfile.NamedTemporaryFile(prefix="s5-terminal-evidence-") as log:
        # A wrong credential card can contain a password other than the fixture's.
        # Drop all proxy URI lines as well as lines containing the known password.
        for line in output.splitlines(keepends=True):
            if secret not in line and b"socks5://" not in line and b"http://" not in line:
                log.write(line)
        log.flush()
        subprocess.run([
            "sh", ".github/scripts/run-socks5.sh", "--diagnose", "install",
            "/dev/null", log.name, passfile,
        ], check=False, timeout=30)


def main():
    if len(sys.argv) != 5:
        print("usage: terminal_install.py ANSWERS PASSFILE PORT LANGUAGE_PROMPTS", file=sys.stderr)
        return 2
    output = b""
    credentials = []
    try:
        answers, passfile, port, prompts = sys.argv[1:]
        prompts = int(prompts)
        if prompts not in (0, 1) or not port.isdecimal() or not 1024 <= int(port) <= 65535:
            raise TerminalFailure("invalid terminal probe arguments")
        with open(passfile, encoding="utf-8") as source:
            credentials = source.read().splitlines()
        if len(credentials) != 2 or not all(credentials):
            raise TerminalFailure("passfile must contain a username and password")
        output = capture_terminal(["sh", "socks5.sh", "install"], answers)
        verify_card(output, credentials[0], credentials[1], port, prompts)
    except TerminalFailure as error:
        print("terminal_install: %s" % error, file=sys.stderr)
        if len(credentials) == 2 and all(credentials):
            try:
                report_failure(error.output or output, passfile, credentials[1])
            except (OSError, subprocess.TimeoutExpired):
                print("terminal_install: could not collect redacted evidence", file=sys.stderr)
        return 1
    except (OSError, ValueError):
        # Exception details can include input bytes; neither they nor the raw
        # terminal transcript may reach CI logs, even when an assertion fails.
        print("terminal_install: could not run or read the terminal probe", file=sys.stderr)
        return 1
    print("terminal_install=ok language_prompts=%d credential_card=ok" % prompts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
