#!/usr/bin/env python3
"""Self-test for the duplex target's frame writer and metrics writer.

Both halves are the same class of bug: two threads touching one shared thing with
no mutual exclusion.

The frame writer sends each frame in two pieces so the client has to reassemble
it. Two threads write the same connection -- the echo path and the unsolicited
server-frame sender -- so those two pieces must not interleave. When they do, the
client reads a spliced stream: with a small frame the split lands inside the cid
field, so the header still parses and the mismatch surfaces as a wrong cid and
nonce rather than as a bad magic.

The metrics writer is what the protocol gate reconciles its own frame counters
against. Its report is written to a temporary and renamed into place, so two
concurrent writers must neither share that temporary -- one truncates the other's
bytes and renames it away, which surfaces as a spliced report or a
FileNotFoundError from the rename -- nor read the counters at the same time.

Every interleaving here is forced rather than raced. A writer holds a fixed gap
in the middle of its work and the second writer starts inside that gap: for
frames, between the two pieces; for metrics, between a temporary file's write and
its close. A writer that serialises correctly makes the second wait, so this is
deterministic in both directions and never deadlocks.
"""

import json
import os
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import duplex_target  # noqa: E402

GAP = 0.25
FAILURES = []
CHECKS = []


def check(label, ok):
    CHECKS.append(label)
    if ok:
        print("ok - %s" % label)
    else:
        print("not ok - %s" % label)
        FAILURES.append(label)


class GappedSocket:
    """Wraps a socket and holds a fixed gap after the first send of each frame."""

    def __init__(self, sock, gap):
        self._sock = sock
        self._gap = gap
        self._seen = 0

    def sendall(self, data):
        self._sock.sendall(data)
        self._seen += 1
        if self._seen % 2 == 1 and self._gap:
            time.sleep(self._gap)


class GappedOpen:
    """Stands in for open() inside duplex_target, gapping one thread only.

    The gap sits between a temporary file's write and its close, so a second
    writer let in during the gap truncates and renames that temporary before the
    first writer has flushed or renamed it.
    """

    def __init__(self, gap):
        self._gap = gap
        self.slow_ident = None
        self.inside = threading.Event()

    def __call__(self, path, mode="r", **kwargs):
        handle = open(path, mode, **kwargs)
        if threading.get_ident() != self.slow_ident:
            return handle
        return GappedHandle(handle, self._gap, self.inside)


class GappedHandle:
    """A file handle that signals, then holds the gap, before it closes."""

    def __init__(self, handle, gap, inside):
        self._handle = handle
        self._gap = gap
        self._inside = inside

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        self._inside.set()
        time.sleep(self._gap)
        return self._handle.__exit__(*exc_info)

    def write(self, text):
        return self._handle.write(text)


def run_paired(slow_call, fast_call):
    """Run two writers so the second runs entirely inside the first's gap.

    The fast writer starts on the signal the gapped handle raises from inside the
    slow writer's temporary file, so the overlap is forced rather than raced. A
    writer that serialises makes the fast one wait for the lock instead, which the
    finish order records.

    Returns the order the two finished in, what each raised, and any that hung.
    """
    gapped = GappedOpen(GAP)
    order = []
    order_lock = threading.Lock()
    errors = {}

    def record(label, call):
        try:
            call()
        except Exception as exc:  # whatever a writer raises is a reported check
            errors[label] = "%s: %s" % (type(exc).__name__, exc)
        with order_lock:
            order.append(label)

    def slow():
        gapped.slow_ident = threading.get_ident()
        try:
            record("slow", slow_call)
        finally:
            gapped.inside.set()

    def fast():
        gapped.inside.wait(10)
        record("fast", fast_call)

    duplex_target.open = gapped
    threads = [
        threading.Thread(target=slow, name="slow", daemon=True),
        threading.Thread(target=fast, name="fast", daemon=True),
    ]
    try:
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(30)
    finally:
        del duplex_target.open
    return order, errors, [thread.name for thread in threads if thread.is_alive()]


def locked_metrics(count_path, report_path):
    with duplex_target.COUNT_LOCK:
        duplex_target.write_metrics(count_path, report_path)


def slurp(path):
    """The file's text, or None when no writer managed to rename one into place."""
    try:
        with open(path, encoding="ascii") as handle:
            return handle.read()
    except OSError:
        return None


def read_frames(sock, expected, deadline):
    frames = []
    buffered = b""
    while len(frames) < expected:
        if time.monotonic() >= deadline:
            break
        sock.settimeout(max(0.05, deadline - time.monotonic()))
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        buffered += chunk
        while len(buffered) >= 6:
            if buffered[:2] != duplex_target.MAGIC:
                return frames, "spliced stream: magic is %r" % buffered[:2]
            length = struct.unpack("!I", buffered[2:6])[0]
            if len(buffered) < 6 + length:
                break
            body = buffered[6:6 + length]
            buffered = buffered[6 + length:]
            frames.append((body[0], struct.unpack("!II", body[1:9])[0], body[9:17]))
    return frames, None


def frame_writer_checks():
    reader, writer_sock = socket.socketpair()
    try:
        writer = duplex_target.FrameWriter(GappedSocket(writer_sock, 0.05))
        echo = duplex_target.frame(ord("E"), 4242, 7, b"NONCE-AA", b"echo")
        server = duplex_target.frame(ord("S"), 4242, 0, b"NONCE-AA", b"server-0")

        first = threading.Thread(target=writer.send, args=(echo,))
        second = threading.Thread(target=writer.send, args=(server,))
        first.start()
        time.sleep(0.01)
        second.start()
        first.join(10)
        second.join(10)
        check("both writers finished", not first.is_alive() and not second.is_alive())

        frames, problem = read_frames(reader, 2, time.monotonic() + 5)
        check("the stream carries no spliced frame", problem is None)
        if problem:
            print("# %s" % problem)
        check("both frames arrived intact", len(frames) == 2)
        kinds = sorted(f[0] for f in frames)
        check("one echo and one server frame", kinds == sorted([ord("E"), ord("S")]))
        check("every frame keeps its cid", all(f[1] == 4242 for f in frames))
        check("every frame keeps its nonce", all(f[2] == b"NONCE-AA" for f in frames))
    finally:
        reader.close()
        writer_sock.close()


def text_writer_checks(scratch):
    path = os.path.join(scratch, "shared")
    # The gapped writer takes the shorter text, so a flush that lands on the other
    # writer's bytes leaves a tail behind and the splice is visible in the file.
    slow_text = "A" * 40 + "\n"
    fast_text = "B" * 200 + "\n"
    # Both writers race for one path here, so the finish order carries no meaning:
    # write_text takes no lock. What matters is that neither corrupts the other.
    _, errors, hung = run_paired(
        lambda: duplex_target.write_text(path, slow_text),
        lambda: duplex_target.write_text(path, fast_text),
    )
    check("both file writers finished", not hung)
    check("neither file writer raised", not errors)
    for label in sorted(errors):
        print("# %s writer: %s" % (label, errors[label]))
    written = slurp(path)
    whole = written in (slow_text, fast_text)
    check("the file holds one whole text and no splice", whole)
    if not whole:
        print("# file holds %r" % ((written or "")[:64],))


def metrics_writer_checks(scratch):
    duplex_target.ACCEPTED = 7
    duplex_target.FRAMES = 11
    del duplex_target.FAMILIES[:]
    duplex_target.FAMILIES.extend(["ipv4", "ipv6"])
    count_path = os.path.join(scratch, "count")
    report_path = os.path.join(scratch, "report")
    order, errors, hung = run_paired(
        lambda: duplex_target.write_metrics(count_path, report_path),
        lambda: duplex_target.write_metrics(count_path, report_path),
    )
    check("both metrics writers finished", not hung)
    check("neither metrics writer raised", not errors)
    for label in sorted(errors):
        print("# %s metrics writer: %s" % (label, errors[label]))
    check("the second metrics write waits for the first", order == ["slow", "fast"])
    if order != ["slow", "fast"]:
        print("# metrics writers finished in the order %s" % ",".join(order))

    report = None
    problem = None
    try:
        report = json.loads(slurp(report_path) or "")
    except ValueError as exc:
        problem = str(exc)
    check("the report is readable JSON", problem is None)
    if problem:
        print("# %s" % problem)
    check("the report holds every counter",
          report == {"accepted": 7, "frames": 11, "families": ["ipv4", "ipv6"]})
    check("the count file holds the accepted count", slurp(count_path) == "7\n")

    # Last, and on a daemon thread: a metrics lock that is not reentrant leaves
    # this writer blocked while it still holds the lock, which would wedge every
    # call after it rather than fail one check.
    holder = threading.Thread(
        target=locked_metrics, args=(count_path, report_path), daemon=True
    )
    holder.start()
    holder.join(5)
    check("write_metrics runs with the count lock already held", not holder.is_alive())


def main():
    frame_writer_checks()
    scratch = tempfile.mkdtemp(prefix="s5target.")
    try:
        text_writer_checks(scratch)
        metrics_writer_checks(scratch)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    print("TESTS %d %d" % (len(CHECKS) - len(FAILURES), len(FAILURES)))
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
