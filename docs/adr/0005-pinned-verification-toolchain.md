# ADR-0005: Transport and verification tools use packaged absolute paths

## Status

Accepted. Implemented in the asset pipeline and precheck of `socks5.sh`.

## Context

A real Alpine 3.22 host reported `Xray asset verification failed: binary-size`
while the mirrored archive was byte-for-byte identical to the official upstream
ZIP and the same script installed correctly on a stock Alpine 3.22.6. The archive
was never the problem: a wrong artifact fails the archive size and SHA-256 gates,
which run first, so reaching the extracted-binary gate proved the accepted
archive had been extracted into different bytes.

The cause was command resolution. Info-ZIP reads `UNZIP`, `UNZIPOPT`, `ZIPINFO`
and `ZIPINFOOPT` as implicit leading command-line options, and `-aa` forces text
conversion: `unzip -p` still exits 0 while rewriting line endings inside the
executable. Clearing those variables around a bare `unzip` is not enough, because
a shell function, an alias or a same-named executable earlier on `PATH` can
re-export them or substitute a different extractor entirely — all three
reproduce the reported failure exactly.

The tools around extraction carried the same exposure. `curl` selected the
transport through `PATH`; `sha256sum` decides whether any file matches any pin,
yet also resolved through `PATH`, so a wrapper makes arbitrary bytes satisfy an
arbitrary pinned digest. `file` resolved through `PATH` and also honours the
`MAGIC` database override, under which the pinned executable is reported as
`data` and refused for the wrong reason.

## Decision

Invoke each transport and verification tool through its packaged absolute path,
behind a one-line internal command seam:

- `s5_curl_command` runs `/usr/bin/curl` for both HTTPS requests.
- `s5_unzip_command` runs `/usr/bin/unzip`; `s5_unzip` is a subshell that unsets
  all four Info-ZIP option variables first.
- `s5_sha256_command` runs `/usr/bin/sha256sum`.
- `s5_file_type_command` runs `/usr/bin/file -b`; `s5_file_type` is a subshell
  that unsets `MAGIC` first.

A subshell, rather than variable assignments prefixed to the call, is what
preserves the caller's own values: POSIX leaves export and persistence
unspecified when assignments precede a shell function. An absolute path, rather
than `command`, is what defeats `PATH`: `command` bypasses functions and aliases
only.

Precheck requires these executables by path — `/usr/bin/sha256sum` for every
command because every command re-checks a recorded digest, and `/usr/bin/curl`,
`/usr/bin/unzip` and `/usr/bin/file` for install and update — and probes
`unzip -Z` for real ZipInfo support, since BusyBox ships a stripped applet
that rejects it. Alpine provisioning requests the packages that supply exactly
those paths.

Each seam stays a single line so focused tests inject failures there instead of
through `PATH`, which is the surface production no longer trusts.

## Alternatives considered

- **Clear the option variables around a bare `unzip`** — rejected: it was the
  first fix and did not resolve the reported failure, because command resolution,
  not the environment, selected the extractor.
- **`command unzip`** — rejected: it bypasses functions and aliases but still
  resolves through `PATH`, which is the part that was compromised.
- **Resolve each tool once during precheck and cache the result** — rejected: the
  resolution itself would still consult `PATH`, so it moves the trust rather than
  removing it, and adds mutable state to a fail-closed path.
- **Reimplement extraction and digests in Python** — rejected: it replaces two
  audited C programs with a larger surface, and `python3` is itself resolved
  through `PATH`, so the exposure would be reproduced one layer up.
- **Accept whatever the host provides and rely on the digest gates** — rejected:
  the digest gate is one of the tools being substituted, so it cannot be the
  backstop for its own substitution.

## Consequences

- `/usr/bin/curl`, `/usr/bin/unzip`, `/usr/bin/sha256sum` and
  `/usr/bin/file` are hard requirements, named in `README.md` and
  `README.zh-CN.md`. All four are present on every supported family after its
  packages are installed: Alpine installs `/usr/bin/curl` from the `curl` package, ships
  `/usr/bin/sha256sum` as a BusyBox applet symlink and `/usr/bin/unzip` from
  Info-ZIP, and supplies `/usr/bin/file` through the `file` package. The systemd
  families install all four at those paths.
- A host that installs one of these tools somewhere else is refused during
  precheck instead of installing an unverified binary (fail closed).
- CI runs the Alpine 3.22 OpenRC lifecycle under a hostile Info-ZIP environment
  and a same-named `PATH` wrapper that records every invocation, and requires the
  wrapper to stay unused while the installed binary matches its pinned size and
  digest. `.github/scripts/alpine-lifecycle.sh` holds that leg.
- Tests override the seams rather than planting executables on `PATH`; a test
  that needs to prove a wrapper is bypassed installs one and asserts it was never
  called.
