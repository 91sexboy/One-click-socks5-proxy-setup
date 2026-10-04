#!/usr/bin/env python3
"""Exercise the memory report's connection holder and its stage coordinator.

A held-connection label is evidence only when every tunnel completed a framed
round trip with the real duplex target, stayed live across the sample, and the
target counted the same tunnels from its side. Each scenario here runs the real
holder (hold_connections.py) and the real coordinator functions
(.github/scripts/memory-hold.sh) against the real target, with a small SOCKS5
stand-in for Xray that can be told to misbehave. No Xray, root or network.
"""

import argparse
import os
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import duplex_target  # noqa: E402
from selftest_support import TapTestCase, run_tests  # noqa: E402

SHELL = ["sh"]
STAGE = 3
# The coordinator, run as one shell so the holder stays its direct child. Each
# step exits with its own status, so a scenario names the step that refused.
COORDINATOR = r'''
set -eu
. .github/scripts/lifecycle-common.sh
. .github/scripts/memory-hold.sh
dir=$1 stage=$2 proxy_port=$3 target_port=$4 scenario=$5
holder_pid=''
# interrupt <point>: break the hold at the point the scenario names.
interrupt() {
    [ "${scenario%%:*}" = "$1" ] || return 0
    case ${scenario#*:} in
    cut)
        : >"$dir/started"
        lifecycle_wait_until 200 0.05 test -e "$dir/go" || exit 19
        ;;
    kill | term)
        kill "-$(echo "${scenario#*:}" | tr a-z A-Z)" "$holder_pid"
        lifecycle_wait_until 50 0.1 memory_holder_gone "$holder_pid" || exit 19
        ;;
    esac
}
memory_hold_start "$dir" "$stage" "$proxy_port" 127.0.0.1 "$target_port" || exit 11
interrupt ready
memory_hold_verify "$dir" "$stage" before_sample || exit 13
printf 'selftest_sampled=%s\n' "$stage"
interrupt sample
memory_hold_verify "$dir" "$stage" after_sample || exit 14
interrupt stop
memory_hold_stop "$dir" "$stage" || exit 15
'''


class FakeProxy:
    """A SOCKS5 stand-in that grants every CONNECT before it dials, as Xray does.

    relay     forwards to the requested destination, closing on a failed dial
    silent    grants, then swallows everything and never answers
    impostor  grants, then answers as a duplex target itself, so the client sees
              valid echoes the real target never counted
    """

    def __init__(self, mode):
        self.mode = mode
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(256)
        self.listener.settimeout(0.1)
        self.port = self.listener.getsockname()[1]
        self.stopped = threading.Event()
        self.lock = threading.Lock()
        self.sockets = []
        self.relays = []
        self.threads = []
        self.acceptor = threading.Thread(target=self._accept, daemon=True)
        self.acceptor.start()

    def _track(self, sock):
        with self.lock:
            self.sockets.append(sock)
        return sock

    def _accept(self):
        while not self.stopped.is_set():
            try:
                sock, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            thread = threading.Thread(target=self._serve, args=(self._track(sock),), daemon=True)
            with self.lock:
                self.threads.append(thread)
            thread.start()

    @staticmethod
    def _read(sock, size):
        data = b""
        while len(data) < size:
            chunk = sock.recv(size - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    def _serve(self, client):
        try:
            client.settimeout(30)
            self._read(client, 3)
            client.sendall(b"\x05\x02")
            ulen = self._read(client, 2)[1]
            self._read(client, ulen)
            plen = self._read(client, 1)[0]
            self._read(client, plen)
            client.sendall(b"\x01\x00")
            request = self._read(client, 10)
            host = socket.inet_ntoa(request[4:8])
            port = struct.unpack("!H", request[8:10])[0]
            client.sendall(b"\x05\x00\x00\x01" + b"\0" * 6)
            if self.mode == "silent":
                while client.recv(65536):
                    pass
                return
            if self.mode == "impostor":
                duplex_target.serve_connection(client, None, None)
                return
            try:
                upstream = self._track(socket.create_connection((host, port), timeout=3))
            except OSError:
                return
            with self.lock:
                self.relays.append((client, upstream))
            pump = threading.Thread(target=self._pump, args=(upstream, client), daemon=True)
            pump.start()
            self._pump(client, upstream)
            pump.join(5)
        except (EOFError, OSError):
            pass
        finally:
            client.close()

    @staticmethod
    def _pump(source, sink):
        try:
            while True:
                data = source.recv(65536)
                if not data:
                    break
                sink.sendall(data)
        except OSError:
            pass
        finally:
            for sock in (source, sink):
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def cut(self):
        """Drop every relayed tunnel after readiness, both directions at once."""
        with self.lock:
            relays = list(self.relays)
        for pair in relays:
            for sock in pair:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass

    def close(self):
        self.stopped.set()
        self.listener.close()
        self.acceptor.join(2)
        with self.lock:
            sockets = list(self.sockets)
            threads = list(self.threads)
        for sock in sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        for thread in threads:
            thread.join(5)


def closed_port():
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def holder_processes(marker):
    """Live hold_connections.py processes whose arguments name this scenario."""
    found = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % entry, "rb") as handle:
                argv = handle.read().split(b"\0")
            with open("/proc/%s/stat" % entry, encoding="ascii", errors="replace") as handle:
                state = handle.read().rsplit(")", 1)[1].split()[0]
        except (OSError, IndexError):
            continue
        if state != "Z" and any(b"hold_connections.py" in arg for arg in argv) \
                and any(marker.encode() in arg for arg in argv):
            found.append(int(entry))
    return found


class Scenario:
    """One coordinator run against a fresh target and a fake proxy."""

    def __init__(self, mode, unreachable=False, stale_ready=False):
        self.mode = mode
        self.unreachable = unreachable
        self.stale_ready = stale_ready
        self.out = self.err = ""
        self.status = None
        self.elapsed = 0.0
        self.leftover = []
        self.ready_left = False
        self.holder_log = ""

    def run(self, scenario="none", on_started=None):
        with tempfile.TemporaryDirectory(prefix="s5hold.") as directory:
            passfile = os.path.join(directory, "pass")
            with open(passfile, "w", encoding="ascii") as handle:
                handle.write("fixture_user\nfixture_password\n")
            os.chmod(passfile, 0o600)
            port_file = os.path.join(directory, "target.port")
            target = subprocess.Popen(
                [sys.executable, os.path.join(HERE, "duplex_target.py"), "--host", "127.0.0.1",
                 "--host6", "::1", "--ready-file", port_file,
                 "--count-file", os.path.join(directory, "count"),
                 "--report-file", os.path.join(directory, "report")],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            proxy = FakeProxy(self.mode)
            try:
                deadline = time.monotonic() + 10
                while not os.path.exists(port_file) or not os.path.exists(os.path.join(directory, "report")):
                    if time.monotonic() > deadline:
                        raise AssertionError("the duplex target never became ready")
                    time.sleep(0.02)
                with open(port_file, encoding="ascii") as handle:
                    target_port = int(handle.read())
                if self.unreachable:
                    target_port = closed_port()
                if self.stale_ready:
                    with open(os.path.join(directory, "held"), "w", encoding="ascii") as handle:
                        handle.write("%d\n" % STAGE)
                started = time.monotonic()
                env = dict(os.environ, MEMORY_HOLD_ROUND_SECONDS="2")
                process = subprocess.Popen(
                    SHELL + ["-c", COORDINATOR, "coordinator", directory, str(STAGE),
                             str(proxy.port), str(target_port), scenario],
                    cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                if on_started is not None:
                    deadline = time.monotonic() + 15
                    while not os.path.exists(os.path.join(directory, "started")):
                        if process.poll() is not None or time.monotonic() > deadline:
                            break
                        time.sleep(0.02)
                    else:
                        on_started(proxy)
                        open(os.path.join(directory, "go"), "w").close()
                try:
                    self.out, self.err = process.communicate(timeout=60)
                except subprocess.TimeoutExpired:
                    process.kill()
                    self.out, self.err = process.communicate()
                self.status = process.returncode
                self.elapsed = time.monotonic() - started
                self.leftover = holder_processes(directory)
                for pid in self.leftover:
                    os.kill(pid, signal.SIGKILL)
                self.ready_left = os.path.exists(os.path.join(directory, "held"))
                with open(os.path.join(directory, "held.log"), encoding="ascii", errors="replace") as handle:
                    self.holder_log = handle.read()
            finally:
                proxy.close()
                target.terminate()
                target.wait(10)
        return self

    def lines(self):
        return set(self.out.splitlines())

    def describe(self):
        return "status=%s elapsed=%.1f\nstdout:\n%s\nstderr:\n%s\nholder:\n%s" % (
            self.status, self.elapsed, self.out, self.err, self.holder_log)


class HolderTests(TapTestCase):
    def report(self, result, label, condition):
        if not condition:
            print("# " + result.describe().replace("\n", "\n# "))
        self.check(label, condition)

    def test_live_tunnels(self):
        result = Scenario("relay").run()
        lines = result.lines()
        self.report(result, "verified live tunnels pass every stage step", result.status == 0)
        for when in ("ready", "before_sample", "after_sample"):
            self.report(result, "the %s check echoed every tunnel" % when,
                        "conn%d_%s_echoed_tunnels=%d" % (STAGE, when, STAGE) in lines)
            self.report(result, "the target counted every tunnel at %s" % when,
                        "conn%d_%s_target_active=%d" % (STAGE, when, STAGE) in lines)
        self.report(result, "an expected stop leaves no holder or ready file",
                    not result.leftover and not result.ready_left)


    def refused(self, result, label, status, evidence):
        """A refusal names its step, publishes no evidence after it, and cleans up."""
        self.report(result, label + " is refused at its own step", result.status == status)
        self.report(result, label + " publishes no %s evidence" % evidence,
                    not any(line.startswith("conn%d_%s_" % (STAGE, evidence)) for line in result.lines()))
        self.report(result, label + " leaves no holder or ready file",
                    not result.leftover and not result.ready_left)
        self.report(result, label + " is refused boundedly", result.elapsed < 20)

    def test_target_unreachable(self):
        # Xray grants CONNECT before it dials; a stale ready file must not stand in.
        result = Scenario("relay", unreachable=True, stale_ready=True).run()
        self.refused(result, "a granted handshake to an unreachable target", 11, "ready")
        self.report(result, "the holder names the tunnel and step that failed",
                    "held cid=5000 stage=echo" in result.holder_log)

    def test_no_hello_reply(self):
        result = Scenario("silent").run()
        self.refused(result, "a tunnel that never answers its hello", 11, "ready")
        self.report(result, "the silent tunnel fails on the echo deadline",
                    "stage=echo-wait ProbeTimeout" in result.holder_log)

    def test_target_did_not_count(self):
        result = Scenario("impostor").run()
        self.refused(result, "echoes the target never counted", 11, "ready")
        self.report(result, "the refusal names the target's count",
                    "the target counts 0 live tunnels, not %d" % STAGE in result.err)

    def test_disconnect_after_ready(self):
        result = Scenario("relay").run("ready:cut", on_started=FakeProxy.cut)
        self.refused(result, "tunnels cut after readiness", 13, "before_sample")
        self.report(result, "no sample is taken over cut tunnels",
                    "selftest_sampled=%d" % STAGE not in result.lines())

    def test_disconnect_during_sample(self):
        result = Scenario("relay").run("sample:cut", on_started=FakeProxy.cut)
        self.refused(result, "tunnels cut across the sample", 14, "after_sample")

    def test_holder_killed_after_ready(self):
        result = Scenario("relay").run("ready:kill")
        self.refused(result, "a holder killed after readiness", 13, "before_sample")

    def test_holder_exits_cleanly_too_early(self):
        result = Scenario("relay").run("ready:term")
        self.refused(result, "a holder that stopped before its check", 13, "before_sample")

    def test_holder_gone_before_stop(self):
        result = Scenario("relay").run("stop:kill")
        self.report(result, "a holder gone before its stop request fails the stage", result.status == 15)
        self.report(result, "the early exit is named",
                    "exited before its stop request" in result.err)
        self.report(result, "the early exit leaves no holder", not result.leftover)


def main():
    global SHELL
    parser = argparse.ArgumentParser()
    parser.add_argument("--shell", default="sh")
    args = parser.parse_args()
    SHELL = shlex.split(args.shell)
    return run_tests(unittest.defaultTestLoader.loadTestsFromTestCase(HolderTests))


if __name__ == "__main__":
    sys.exit(main())
