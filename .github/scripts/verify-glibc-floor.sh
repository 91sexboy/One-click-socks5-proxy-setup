#!/bin/sh
set -eu

ASSET=${1:?usage: verify-glibc-floor.sh ASSET MAX_MAJOR MAX_MINOR}
MAX_MAJOR=${2:?usage: verify-glibc-floor.sh ASSET MAX_MAJOR MAX_MINOR}
MAX_MINOR=${3:?usage: verify-glibc-floor.sh ASSET MAX_MAJOR MAX_MINOR}

[ -f "$ASSET" ] && [ ! -L "$ASSET" ] || {
    printf 'GLIBC floor target must be a regular non-symlink file: %s\n' "$ASSET" >&2
    exit 2
}

_versions=$(readelf --version-info "$ASSET" |
    grep -o 'GLIBC_[0-9][0-9.]*' | LC_ALL=C sort -Vu)
[ -n "$_versions" ] || {
    printf 'binary has no GLIBC version requirements: %s\n' "$ASSET" >&2
    exit 1
}

_max_required=$(printf '%s\n' "$_versions" | sed 's/^GLIBC_//' | LC_ALL=C sort -V | tail -n 1)
_highest=$(printf '%s\n%s\n' "$_max_required" "$MAX_MAJOR.$MAX_MINOR" |
    LC_ALL=C sort -V | tail -n 1)
if [ "$_highest" != "$MAX_MAJOR.$MAX_MINOR" ]; then
    printf '%s requires GLIBC_%s, exceeds GLIBC_%s.%s\n' \
        "$ASSET" "$_max_required" "$MAX_MAJOR" "$MAX_MINOR" >&2
    exit 1
fi

printf 'required_glibc_versions=%s\n' "$(printf '%s\n' "$_versions" | paste -sd, -)"
printf 'max_required_glibc=%s\n' "$_max_required"
