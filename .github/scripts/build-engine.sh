#!/bin/sh
set -eu
umask 077

LIBC=${1:?usage: build-engine.sh glibc amd64 OUTDIR}
ARCH=${2:?usage: build-engine.sh glibc amd64 OUTDIR}
OUTDIR=${3:?usage: build-engine.sh glibc amd64 OUTDIR}
BUILDER_IMAGE=${S5_BUILDER_IMAGE:?S5_BUILDER_IMAGE must identify the pinned builder image}

UPSTREAM_URL=https://github.com/3proxy/3proxy
UPSTREAM_TAG=0.9.9.0
UPSTREAM_COMMIT=da99424eac4092e3722f1a5b1844cfe80478f580
ASSET=3proxy-0.9.9.0-da99424-linux-glibc-amd64
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

[ "$LIBC:$ARCH" = glibc:amd64 ] || {
    printf 'r2 builder supports only glibc:amd64; other assets are carried from r1: %s:%s\n' \
        "$LIBC" "$ARCH" >&2
    exit 2
}
case "$(uname -m)" in
x86_64 | amd64) ;;
*) printf 'r2 glibc-amd64 builder requires native amd64\n' >&2; exit 2 ;;
esac

_ldd=$(ldd --version 2>&1 || true)
printf '%s\n' "$_ldd" | grep -qiE 'glibc|GNU libc' || {
    printf 'glibc builder required\n' >&2
    exit 2
}

mkdir -p "$OUTDIR"
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/s5-engine.XXXXXX")
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT HUP INT TERM
SRC="$WORK/3proxy"
LOG="$WORK/build.log"

git clone --quiet --depth 1 --single-branch --no-checkout \
    --branch "$UPSTREAM_TAG" "$UPSTREAM_URL" "$SRC"
git -C "$SRC" checkout --quiet --detach "$UPSTREAM_COMMIT"
HEAD=$(git -C "$SRC" rev-parse HEAD | tr -d '[:space:]')
[ "$HEAD" = "$UPSTREAM_COMMIT" ] || {
    printf 'upstream HEAD mismatch: expected %s, got %s\n' "$UPSTREAM_COMMIT" "${HEAD:-empty}" >&2
    exit 1
}

mkdir -p "$SRC/bin"
if ! (
    unset MAKEFLAGS MFLAGS GNUMAKEFLAGS CFLAGS CPPFLAGS CXXFLAGS LDFLAGS
    make -j1 -C "$SRC/src" -f ../Makefile.Linux \
        WOLFSSL_CHECK=false OPENSSL_CHECK=false PCRE_CHECK=false PAM_CHECK=false \
        PLUGINS= EXTRA_CFLAGS='-O2 -fno-lto' EXTRA_LDFLAGS='-fno-lto' \
        ../bin/3proxy
) >"$LOG" 2>&1; then
    tail -n 40 "$LOG" >&2
    exit 1
fi

BIN="$SRC/bin/3proxy"
[ -f "$BIN" ] && [ ! -L "$BIN" ] && [ -x "$BIN" ] || {
    printf 'build did not produce an executable regular file\n' >&2
    exit 1
}
strip "$BIN"
cp "$BIN" "$OUTDIR/$ASSET"
chmod 0755 "$OUTDIR/$ASSET"

_header=$(readelf -h "$OUTDIR/$ASSET")
printf '%s\n' "$_header" | grep -q 'Class:[[:space:]]*ELF64'
printf '%s\n' "$_header" | grep -q 'Machine:[[:space:]]*Advanced Micro Devices X86-64'
_program=$(readelf -l "$OUTDIR/$ASSET")
printf '%s\n' "$_program" | grep -Fq 'Requesting program interpreter: /lib64/ld-linux-x86-64.so.2'

_dynamic=$(readelf -d "$OUTDIR/$ASSET")
if printf '%s\n' "$_dynamic" | grep -qE '\((RPATH|RUNPATH)\)'; then
    printf 'release binary must not contain RPATH/RUNPATH\n' >&2
    exit 1
fi
_needed=$(printf '%s\n' "$_dynamic" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
[ -n "$_needed" ] || { printf 'release binary has no dynamic libc dependency\n' >&2; exit 1; }
for _lib in $_needed; do
    case "$_lib" in
    libc.so.6 | libpthread.so.0 | libdl.so.2 | libm.so.6 | librt.so.1 | libgcc_s.so.1) ;;
    *) printf 'unexpected runtime dependency: %s\n' "$_lib" >&2; exit 1 ;;
    esac
done

_glibc_info=$("$SCRIPT_DIR/verify-glibc-floor.sh" "$OUTDIR/$ASSET" 2 31)
(
    cd "$OUTDIR"
    sha256sum "$ASSET" >"$ASSET.sha256"
)
{
    printf 'asset=%s\n' "$ASSET"
    printf 'upstream_url=%s\n' "$UPSTREAM_URL"
    printf 'upstream_tag=%s\n' "$UPSTREAM_TAG"
    printf 'upstream_commit=%s\n' "$UPSTREAM_COMMIT"
    printf 'libc=%s\n' "$LIBC"
    printf 'arch=%s\n' "$ARCH"
    printf 'builder_image=%s\n' "$BUILDER_IMAGE"
    printf 'builder_os=%s\n' "$(. /etc/os-release 2>/dev/null; printf '%s-%s' "${ID:-unknown}" "${VERSION_ID:-unknown}")"
    printf 'builder_libc_version=%s\n' "$(printf '%s\n' "$_ldd" | head -n 1)"
    printf 'compiler=%s\n' "$(cc --version | head -n 1)"
    printf '%s\n' "$_glibc_info"
    printf 'sha256=%s\n' "$(sha256sum "$OUTDIR/$ASSET" | cut -d' ' -f1)"
    printf 'size=%s\n' "$(wc -c <"$OUTDIR/$ASSET" | tr -d '[:space:]')"
} >"$OUTDIR/$ASSET.build-info"
chmod 0644 "$OUTDIR/$ASSET.sha256" "$OUTDIR/$ASSET.build-info"
