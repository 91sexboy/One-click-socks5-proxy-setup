#!/usr/bin/env python3
"""Exercise lock reclamation with two live shell processes and a fixed interleaving."""

import os
from pathlib import Path
import select
import shlex
import subprocess
import sys
import tempfile


def line(process):
    if not select.select([process.stdout], [], [], 5)[0]:
        raise AssertionError("lock participant did not reach its barrier")
    return process.stdout.readline().strip()


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


def race(source, shell):
    with tempfile.TemporaryDirectory(prefix="s5-lock-race.") as directory:
        root = Path(directory)
        (root / ".s5-test-root").touch()
        lock = root / "run/xray-socks5.lock"
        lock.mkdir(parents=True)
        departed = subprocess.Popen([*shell, "-c", "exit 0"])
        departed.wait(timeout=5)
        boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
        (lock / "owner").write_text(f"{boot}\n{departed.pid}\n")
        env = dict(os.environ, S5_TEST_MODE="1", S5_TEST_ROOT=directory,
                   S5_LIB_ONLY="1", S5_ASSUME_ROOT="1")
        program = r'''
. "$1"
S5_LANG=en
pause=$2
rm() {
    if [ "$pause" = yes ] && [ "${1:-}" = -f ] &&
        { [ "${2:-}" = "$S5_LOCK_OWNER" ] || [ "${2:-}" = owner ]; }; then
        pause=no
        printf 'reclaim-ready\n'
        IFS= read -r gate || return 1
    fi
    command rm "$@"
}
rc=0
s5_lock_acquire || rc=$?
printf 'acquire=%s held=%s\n' "$rc" "$S5_LOCK_HELD"
IFS= read -r gate || exit 3
released=0
s5_lock_release || released=$?
printf 'release=%s\n' "$released"
[ "$rc" = 0 ] && [ "$released" = 0 ]
'''
        processes = []
        try:
            def start(pause):
                process = subprocess.Popen(
                    [*shell, "-c", program, "lock-race", str(source), pause],
                    env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True,
                )
                processes.append(process)
                return process

            first = start("yes")
            assert line(first) == "reclaim-ready", "first reclaimer did not pause"
            second = start("no")
            assert line(second) == "acquire=0 held=1", "second operation did not acquire"
            first_out, first_err = first.communicate("continue\nfinish\n", timeout=5)
            assert second.poll() is None, "lock holder exited before competing acquisition"
            second_out, second_err = second.communicate("finish\n", timeout=5)
            assert "acquire=0 held=1" not in first_out, (
                "both operations acquired while the second holder was alive"
            )
            assert first.returncode != 0, first_err
            assert second.returncode == 0 and "release=0" in second_out, second_err
            assert not lock.exists(), "winning holder could not cleanly release"
        finally:
            for process in processes:
                stop(process)


def rollback_exit(source, shell):
    with tempfile.TemporaryDirectory(prefix="s5-rollback-lock.") as directory:
        env = {key: value for key, value in os.environ.items() if not key.startswith("S5_")}
        env.update(S5_REPO_ROOT=str(source.parent), TMPDIR=directory)
        program = r'''
. "$S5_REPO_ROOT/tests/lib/assert.sh"
. "$S5_REPO_ROOT/tests/lib/xray-fixture.sh"
t_xray_fixture
t_xray_install
printf 'root=%s\n' "$S5_TEST_ROOT"
s5_precheck() { return 0; }
s5_prompt_port() { S5_PORT=24567; }
s5_state_write() { : >"$S5_TEST_ROOT/fail-restore"; return 1; }
mktemp() {
    if [ -f "$S5_TEST_ROOT/fail-restore" ]; then
        case "$1" in "$S5_STATEDIR"/.s5tmp.*) return 1 ;; esac
    fi
    command mktemp "$@"
}
paused=0
rmdir() {
    command rmdir "$@" || return $?
    if [ "$1" = "$S5_LOCKDIR" ] && [ "$paused" = 0 ]; then
        paused=1
        printf 'released-first\n'
        IFS= read -r gate || return 1
        rm -f "$S5_TEST_ROOT/fail-restore"
    fi
}
s5_cmd_install
'''
        first = second = None
        try:
            first = subprocess.Popen([*shell, "-c", program], env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, text=True)
            root_line = line(first)
            assert root_line.startswith("root="), root_line
            root = Path(root_line[5:])
            assert line(first) == "released-first", "first command did not release its lock"
            holder = r'''
. "$S5_REPO_ROOT/socks5.sh"
S5_LANG=en
s5_lock_acquire || exit 2
printf 'second-held\n'
IFS= read -r gate || exit 3
s5_lock_release
'''
            holder_env = dict(env, S5_TEST_ROOT=str(root), S5_TEST_MODE="1", S5_LIB_ONLY="1")
            second = subprocess.Popen([*shell, "-c", holder], env=holder_env,
                                      stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True)
            assert line(second) == "second-held", "second command did not acquire"
            config = root / "etc/xray-socks5/config.json"
            transcript = root / "transcript"
            transaction = root / "var/lib/xray-socks5/transaction"
            inode = config.stat().st_ino
            events = transcript.read_bytes()
            backups = {name: (transaction / name).read_bytes()
                       for name in ("old.config.json", "old.state")}
            first.communicate("resume\n", timeout=5)
            assert first.returncode != 0, "failed update reported success"
            assert second.poll() is None, "second lock holder exited too soon"
            assert config.stat().st_ino == inode, "EXIT cleanup rewrote config without holding the lock"
            assert transcript.read_bytes() == events, "EXIT cleanup restarted service without the lock"
            assert all((transaction / name).read_bytes() == data for name, data in backups.items()), (
                "EXIT cleanup removed recovery evidence without the lock"
            )
            second.communicate("release\n", timeout=5)
            assert second.returncode == 0, "second command could not release its lock"
        finally:
            for process in (first, second):
                if process is not None:
                    stop(process)


def controls(source, shell):
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    departed = subprocess.Popen([*shell, "-c", "exit 0"])
    departed.wait(timeout=5)
    cases = [
        ("new", None, True),
        ("live", f"{boot}\n{os.getpid()}\n", False),
        ("departed", f"{boot}\n{departed.pid}\n", True),
        ("previous-boot", f"previous-boot\n{os.getpid()}\n", True),
        ("absent", None, False),
        ("bad-pid", f"{boot}\nnot-a-pid\n", False),
        ("zero-pid", f"{boot}\n0\n", False),
        ("extra-line", f"previous-boot\n123\nextra\n", False),
        ("symlink", f"previous-boot\n123\n", False),
    ]
    for name, owner, accepted in cases:
        with tempfile.TemporaryDirectory(prefix="s5-lock-control.") as directory:
            root = Path(directory)
            (root / ".s5-test-root").touch()
            lock = root / "run/xray-socks5.lock"
            if name != "new":
                lock.mkdir(parents=True)
                if owner is not None:
                    if name == "symlink":
                        (root / "external-owner").write_text(owner)
                        (lock / "owner").symlink_to(root / "external-owner")
                    else:
                        (lock / "owner").write_text(owner)
            env = dict(os.environ, S5_TEST_MODE="1", S5_TEST_ROOT=directory,
                       S5_LIB_ONLY="1", S5_ASSUME_ROOT="1")
            result = subprocess.run(
                [*shell, "-c", '. "$1"; S5_LANG=en; s5_lock_acquire && s5_lock_release',
                 "lock-control", str(source)], env=env, capture_output=True,
                text=True, timeout=5,
            )
            assert (result.returncode == 0) == accepted, name
            if accepted:
                assert not lock.exists(), name
            else:
                assert lock.is_dir(), name
                if owner is not None:
                    assert (lock / "owner").read_text() == owner, name
                if name == "symlink":
                    assert (lock / "owner").is_symlink(), name


if __name__ == "__main__":
    source = Path(sys.argv[1]).resolve()
    shell = shlex.split(sys.argv[2])
    if sys.argv[3:] == ["rollback-exit"]:
        rollback_exit(source, shell)
        print("rollback stops before releasing operation lock")
    elif not sys.argv[3:]:
        race(source, shell)
        controls(source, shell)
        print("stale-lock interleaving preserves mutual exclusion")
    else:
        raise SystemExit("unknown lock regression scenario")
