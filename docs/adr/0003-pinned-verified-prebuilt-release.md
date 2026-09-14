# ADR-0003: Pinned, fully verified prebuilt release; no source build

## Status

Accepted. Implemented in the asset pipeline of `socks5.sh`.

## Context

The installer runs as root and publishes a long-lived service binary. What it
installs must be exactly the intended artifact, verifiable offline after the
download, on a target that carries no build toolchain.

## Decision

Pin the official stable Xray-core version and tag commit, plus the
per-architecture archive size and SHA-256 and the extracted-`xray` binary size
and SHA-256. Distribute unchanged official ZIPs through
[this repository's Release mirror](https://github.com/91sexboy/One-click-socks5-proxy-setup/releases),
using the `xray-<version>` release tag with no fallback to upstream or another
mirror. This keeps distribution under the repository's release management while
preserving the official bytes as the identity checked independently of the
mirror's contents; a different or unavailable asset fails closed.

Download only over HTTPS with a transfer timeout and exact post-download size
validation. The installer's `--max-filesize` check does not bound chunked replies
without Content-Length. Verify the archive size and SHA-256 before extraction;
inspect archive members and reject unsafe paths, links, devices, duplicates, and
unexpected members; install only the verified `xray` executable and re-check its
recorded hash on every later command. See `s5_asset_select` in the
[installer](../../socks5.sh) for the current pins.

## Alternatives considered

- **A `latest` / dev channel** — rejected: unpinned downloads make the installed
  bytes unverifiable and the install unreproducible.
- **Build from source** — rejected: the target receives no Go, Git, GCC, Make, or
  headers; a build toolchain is a large attack and maintenance surface
  for what is a static prebuilt binary.
- **Automatic source fallback** — rejected: it hides which distribution source
  supplied the bytes and makes mirror failures invisible; the selected release
  source must succeed under the same fixed pins or installation fails.
- **Verify the archive only** — rejected: the extracted binary is pinned
  separately, so a tampered member inside a correctly-sized archive is still
  refused, and state re-verification can detect a later on-disk swap.

## Consequences

- Bumping Xray requires deliberate updates to the version, tag commit and
  per-architecture asset metadata in `socks5.sh`, `.github/workflows/ci.yml`,
  `tests/protocol/start_engine.sh`, and the independent pin table in
  `tests/lib/release_contract.py`. Update the release tags and published sizes in
  `README.md` and `README.zh-CN.md`, and the independent expectations in
  `tests/lib/release_contract_regression.py`. The release-contract oracle and
  its mutation regressions retain independent expectations rather than deriving
  the expected bytes from the production declarations.
- A wrong pin refuses every install on that architecture rather than installing an
  unverified binary (fail closed).
- No GeoIP database ever reaches disk, which is why the destination boundary uses
  literal CIDRs ([ADR-0002](0002-literal-cidr-destination-boundary.md)).
