#!/bin/sh
# The runner images ship the tools the installer and the protocol checks run, so
# the jobs confirm them instead of installing them again. curl and file are
# checked at the absolute paths the installer requires.
set -eu
for tool in python3 ss; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'runner tools: %s is missing from the runner image\n' "$tool" >&2
        exit 1
    }
done
for tool in /usr/bin/curl /usr/bin/file; do
    [ -x "$tool" ] || {
        printf 'runner tools: %s is missing from the runner image\n' "$tool" >&2
        exit 1
    }
done
printf 'runner tools: python3, ss, curl and file are preinstalled\n'
