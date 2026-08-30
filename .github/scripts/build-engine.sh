#!/bin/sh
set -eu
umask 077

LIBC=${1:?usage: build-engine.sh glibc|musl amd64|arm64 OUTDIR}
ARCH=${2:?usage: build-engine.sh glibc|musl amd64|arm64 OUTDIR}
OUTDIR=${3:?usage: build-engine.sh glibc|musl amd64|arm64 OUTDIR}

UPSTREAM_URL=https://github.com/3proxy/3proxy
UPSTREAM_TAG=0.9.9.0
UPSTREAM_COMMIT=da99424eac4092e3722f1a5b1844cfe80478f580
ASSET="3proxy-${UPSTREAM_TAG}-da99424-linux-${LIBC}-${ARCH}"

case "$LIBC:$ARCH" in
    glibc:amd64 | glibc:arm64 | musl:amd64 | musl:arm64) ;;
    *) printf 'unsupported build tuple: %s:%s\n' "$LIBC" "$ARCH" >&2; exit 2 ;;
esac

case "$(uname -m)" in
    x86_64 | amd64) NATIVE_ARCH=amd64 ;;
    aarch64 | arm64) NATIVE_ARCH=arm64 ;;
    *) printf 'unsupported native architecture: %s\n' "$(uname -m)" >&2; exit 2 ;;
esac
[ "$NATIVE_ARCH" = "$ARCH" ] || {
    printf 'requested architecture %s does not match native %s\n' "$ARCH" "$NATIVE_ARCH" >&2
    exit 2
}

_ldd=$(ldd --version 2>&1 || true)
case "$LIBC" in
    glibc) printf '%s\n' "$_ldd" | grep -qiE 'glibc|GNU libc' || { printf 'glibc builder required\n' >&2; exit 2; } ;;
    musl) printf '%s\n' "$_ldd" | grep -qi musl || { printf 'musl builder required\n' >&2; exit 2; } ;;
esac

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
case "$ARCH" in
    amd64) printf '%s\n' "$_header" | grep -q 'Machine:[[:space:]]*Advanced Micro Devices X86-64' ;;
    arm64) printf '%s\n' "$_header" | grep -q 'Machine:[[:space:]]*AArch64' ;;
esac

_program=$(readelf -l "$OUTDIR/$ASSET")
case "$LIBC:$ARCH" in
    glibc:amd64) _loader='/lib64/ld-linux-x86-64.so.2' ;;
    glibc:arm64) _loader='/lib/ld-linux-aarch64.so.1' ;;
    musl:amd64) _loader='/lib/ld-musl-x86_64.so.1' ;;
    musl:arm64) _loader='/lib/ld-musl-aarch64.so.1' ;;
esac
printf '%s\n' "$_program" | grep -Fq "Requesting program interpreter: $_loader"

_dynamic=$(readelf -d "$OUTDIR/$ASSET")
if printf '%s\n' "$_dynamic" | grep -qE '\((RPATH|RUNPATH)\)'; then
    printf 'release binary must not contain RPATH/RUNPATH\n' >&2
    exit 1
fi
_needed=$(printf '%s\n' "$_dynamic" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p')
[ -n "$_needed" ] || { printf 'release binary has no dynamic libc dependency\n' >&2; exit 1; }
for _lib in $_needed; do
    case "$LIBC:$_lib" in
        glibc:libc.so.6 | glibc:libpthread.so.0 | glibc:libdl.so.2 | glibc:libm.so.6 | glibc:librt.so.1 | glibc:libgcc_s.so.1) ;;
        musl:libc.musl-*.so.1) ;;
        *) printf 'unexpected runtime dependency: %s\n' "$_lib" >&2; exit 1 ;;
    esac
done

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
    printf 'compiler=%s\n' "$(cc --version | head -n 1)"
    printf 'sha256=%s\n' "$(sha256sum "$OUTDIR/$ASSET" | cut -d' ' -f1)"
    printf 'size=%s\n' "$(wc -c <"$OUTDIR/$ASSET" | tr -d '[:space:]')"
} >"$OUTDIR/$ASSET.build-info"
chmod 0644 "$OUTDIR/$ASSET.sha256" "$OUTDIR/$ASSET.build-info"
