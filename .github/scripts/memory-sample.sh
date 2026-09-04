#!/bin/sh
# Print non-secret Xray RSS and cgroup metrics for GitHub Actions.
#
# SPEC 8 records evidence without claiming a universal minimum. OOM counters are
# part of that evidence, so a cgroup that cannot be read is an error rather than
# a silently skipped metric once a cgroup directory has been named.
set -eu

PID=${1:?usage: memory-sample.sh PID LABEL [CGROUP_DIR]}
LABEL=${2:?usage: memory-sample.sh PID LABEL [CGROUP_DIR]}
CGROUP=${3:-}

require_number() {
    case "${1:-}" in
    '' | *[!0-9]*)
        printf 'invalid %s: %s\n' "$2" "${1:-}" >&2
        exit 1
        ;;
    esac
}

read_field() {
    awk -v key="$2" '$1 == key {print $2; found = 1} END {exit found ? 0 : 1}' "$1"
}

rss=$(awk '/^VmRSS:/ {print $2}' "/proc/$PID/status" 2>/dev/null || printf '')
require_number "$rss" VmRSS
printf '%s_rss_kib=%s\n' "$LABEL" "$rss"

[ -n "$CGROUP" ] || exit 0

[ -d "$CGROUP" ] || { printf 'cgroup directory is missing: %s\n' "$CGROUP" >&2; exit 1; }
current=$(cat "$CGROUP/memory.current")
peak=$(cat "$CGROUP/memory.peak")
require_number "$current" memory.current
require_number "$peak" memory.peak
printf '%s_cgroup_current_bytes=%s\n' "$LABEL" "$current"
printf '%s_cgroup_peak_bytes=%s\n' "$LABEL" "$peak"

oom=$(read_field "$CGROUP/memory.events" oom)
oom_kill=$(read_field "$CGROUP/memory.events" oom_kill)
require_number "$oom" 'memory.events oom'
require_number "$oom_kill" 'memory.events oom_kill'
printf '%s_cgroup_oom=%s\n' "$LABEL" "$oom"
printf '%s_cgroup_oom_kill=%s\n' "$LABEL" "$oom_kill"
