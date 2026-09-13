# ADR-0002: Literal-CIDR destination boundary with IPIfNonMatch

## Status

Accepted. Implemented in the engine configuration rendered by `socks5.sh`.

## Context

An authenticated tunnel meant for internet-facing hosts must not become a path to
the proxy host's own loopback, the private and CGNAT ranges, the link-local range
that serves cloud instance metadata (`169.254.169.254`), or ranges a TCP CONNECT
has no business reaching. Reaching any of them is a release blocker.

## Decision

Route a single `blocked` (blackhole) outbound for twelve reserved/special ranges
(nine IPv4 plus IPv6 loopback, ULA, and link-local), written as **literal CIDRs**,
with `domainStrategy: "IPIfNonMatch"` so a hostname destination is matched on the
address it resolves to. This is the only routing rule. See the
[public security boundaries](../../README.md#security-boundaries).

## Alternatives considered

- **`geoip:private`** — rejected: the installer extracts only the `xray`
  executable and places no GeoIP database on disk
  ([ADR-0003](0003-pinned-verified-prebuilt-release.md)), so a geoip rule
  would fail at runtime. Literal CIDRs need no data file.
- **The default `domainStrategy: "AsIs"`** — rejected: an `ip` rule then matches
  only a literal address, so any hostname resolving into a denied range would be
  routed direct — a boundary bypass by name. `IPIfNonMatch` closes that.
- **A GeoIP/GeoSite-based policy** — rejected: out of scope and it pulls
  in the very data files this route avoids.

## Consequences

- The renderer and the independent protocol launcher encode the same twelve
  ranges. `tests/unit/test_xray_docs.sh` checks both against the independent
  [destination-boundary fixture](../../tests/fixtures/denied-destinations.txt),
  so dropping a range from both implementations cannot hide a regression.
- This boundary is distinct from the **advertise-safety check**
  (`s5_ipv4_is_public`), which validates the credential card's own address over a
  different set for a different purpose. The two are deliberately separate and
  cross-referenced in code, not merged.
- CI proves the boundary holds against a target that is listening and answering
  inside it, reached by literal address and by a name resolving into it.
