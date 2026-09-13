#!/usr/bin/env python3
"""Measure state parsing, not whole-command latency or proxy throughput.

Run on one machine before/after with identical --loads/--batches. Artifact and
account verification are stubbed; pinned release metadata checks remain real.
No archive, network request, privileged command, or persistent install is used.
"""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import tempfile
import time

PAYLOAD = r'''
S5_TEST_MODE=1
S5_TEST_ROOT=$2
S5_LIB_ONLY=1
S5_SKIP_OWNERSHIP=1
export S5_TEST_MODE S5_TEST_ROOT S5_LIB_ONLY S5_SKIP_OWNERSHIP
. "$1"
S5_ARCHNAME=amd64
s5_asset_select || exit 1
S5_OS_ID=debian
S5_OS_VERSION_ID=12
S5_OS_FAMILY=debian
S5_INIT=systemd
S5_LISTEN=127.0.0.1
S5_PORT=23456
S5_USERNAME=alice
S5_BINARY_SHA256=$S5_ASSET_BINARY_SHA256
S5_ACCOUNT_UID=900
S5_ACCOUNT_GID=900
S5_CONFIG_SHA256=benchmark-config
S5_UNIT_SHA256=benchmark-unit
mkdir -p "$S5_PREFIX" "$S5_SYSCONFDIR" "$S5_STATEDIR"
s5_state_write || exit 1
s5_verify_installed_artifacts() { return 0; }
s5_account_identity() { return 0; }
# Count calls only on a separate untimed load so file writes do not skew timing.
awk() { printf 'x\n' >>"$S5_TEST_ROOT/awk-count"; command awk "$@"; }
s5_state_load || exit 1
unset -f awk
printf 'READY\n'
# Handshake excludes process startup and fixture preparation from the sample.
IFS= read -r _bench_start || exit 1
_bench_i=0
while [ "$_bench_i" -lt "$3" ]; do
    s5_state_load || exit 1
    _bench_i=$((_bench_i + 1))
done
printf 'DONE\n'
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--script', type=Path,
                        default=Path(__file__).resolve().parents[2] / 'socks5.sh')
    parser.add_argument('--loads', type=int, default=20)
    parser.add_argument('--batches', type=int, default=3)
    args = parser.parse_args()
    if args.loads < 1 or args.batches < 1:
        parser.error('loads and batches must be positive')
    for shell in (['sh'], ['dash'], ['bash'], ['busybox', 'sh']):
        samples, counts = [], []
        for _ in range(args.batches):
            with tempfile.TemporaryDirectory(prefix='s5-state-bench.') as root:
                Path(root, '.s5-test-root').touch()
                env = os.environ.copy()
                env.pop('S5_LISTEN', None)
                with subprocess.Popen(
                    shell + ['-c', PAYLOAD, 'state-benchmark', str(args.script.resolve()),
                             root, str(args.loads)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True, env=env,
                ) as proc:
                    if proc.stdout.readline().strip() != 'READY':
                        raise RuntimeError(proc.stderr.read())
                    start = time.perf_counter()
                    proc.stdin.write('start\n')
                    proc.stdin.flush()
                    done = proc.stdout.readline().strip()
                    elapsed = time.perf_counter() - start
                    _, error = proc.communicate(timeout=30)
                    if done != 'DONE' or proc.returncode:
                        raise RuntimeError(error or 'benchmark load failed')
                samples.append(round(elapsed * 1000 / args.loads, 3))
                counts.append(len(Path(root, 'awk-count').read_text().splitlines()))
        print(json.dumps({'shell': ' '.join(shell), 'loads_per_batch': args.loads,
                          'ms_per_load': samples, 'median_ms': statistics.median(samples),
                          'awk_calls_per_load': counts}), flush=True)


if __name__ == '__main__':
    main()
