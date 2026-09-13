#!/bin/sh
# Keep one Python process (and its read/write memory.peak fd) across every stage.
# stdin protocol: reset LABEL -> LABEL_reset=ok; sample LABEL -> metrics and
# LABEL_sample=ok; quit -> exit. Reset must be acknowledged before workload start.
set -eu
[ "$#" -eq 2 ] || { printf 'usage: memory-sample.sh PID CGROUP_DIR\n' >&2; exit 2; }
exec python3 "$(dirname "$0")/memory-sampler.py" "$1" "$2"
