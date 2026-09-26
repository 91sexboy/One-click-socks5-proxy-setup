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
  `tests/protocol/start_engine.sh` and `tests/unit/test_xray_asset.sh`, and to the
  amd64 binary size and digest that three further files repeat: the two native
  lifecycle gates `.github/scripts/alpine-lifecycle.sh` and
  `.github/scripts/systemd-lifecycle.sh`, which re-check the installed bytes from
  outside the installer, and `tests/unit/test_xray_docs.sh`, which requires that
  they do. That list is enforced rather than remembered: the release contract
  names the first four as `FILES` and the last three as `PIN_MIRRORS`, and a bump
  that misses one is refused — including a 64-hex digest left in a mirror that is
  no longer a current pin.
- The independent pin table in `tests/lib/release_contract.py` and the independent
  expectations in `tests/lib/release_contract_regression.py` are updated by hand
  as well; the oracle and its mutation regressions retain independent expectations
  rather than deriving the expected bytes from the production declarations. Update
  the release tag and published sizes in `README.md` and `README.zh-CN.md`, the
  documented mirror tag in `tests/unit/test_xray_readme.sh`, and the version and
  upstream source links in `THIRD_PARTY_NOTICES.md`.
- A wrong pin refuses every install on that architecture rather than installing an
  unverified binary (fail closed).
- No GeoIP database ever reaches disk, which is why the destination boundary uses
  literal CIDRs ([ADR-0002](0002-literal-cidr-destination-boundary.md)).

## Managed-state compatibility

Recorded release, commit, archive, and binary metadata identify the artifact that
is already installed. They are not required to equal the current script's release
pins for inspection, restart, or uninstall. A recognized older complete state is
validated against its own recorded binary and service/config digests, while an
update independently selects and verifies the current script's pinned candidate.
Historical state data can therefore never satisfy current download verification.
Unknown schemas, malformed fields, ownership drift, and digest drift fail closed
and preserve resources; a trusted uninstall recovery record is the sole exception
that permits resumable removal of the resources it recorded.
