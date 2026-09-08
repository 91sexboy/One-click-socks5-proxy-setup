# ADR-0001: Xray-only "mixed" proxy, replacing 3proxy

## Status

Accepted. Implemented on the `xray-only` route (commit `70a8bea` onward).

## Context

The earlier route installed 3proxy. The goal for this route is a one-command,
single-purpose authenticated proxy that is easy to verify and hard to
misconfigure. 3proxy and panel-based stacks (3x-ui and similar) bring a web
panel, a database, subscription services, and a broad configuration surface
disproportionate to "one account, TCP CONNECT, authenticated" — and hard to pin
and test end to end.

## Decision

Install and manage exactly one pinned Xray-core process, configured with a single
`protocol: "mixed"` inbound that serves both SOCKS5 (RFC 1929) and HTTP-proxy
(Basic) authentication on one port, one account, `udp: false`, one direct
outbound, and one blackhole outbound. No panel, database, API, subscription, or
second engine. The client's URI scheme selects the protocol. See SPEC §1.

## Alternatives considered

- **Keep 3proxy** — rejected: separate SOCKS and HTTP configuration, a weaker
  release-pinning story, and a migration that would have to carry legacy paths.
- **A panel (3x-ui etc.)** — rejected: a database and web surface, and far more
  to secure and verify, against a one-account product.
- **A pure SOCKS5 listener** — rejected: `mixed` gives HTTP-proxy clients the
  same endpoint on one port for free, and the auth discrimination is tested for
  both protocols; a pure listener would need a second inbound for HTTP.

## Consequences

- The route is defined as much by what it refuses (SPEC §9 non-goals): no UDP,
  TLS, REALITY, WS/gRPC/XHTTP, GeoIP/GeoSite, or routing beyond the boundary.
- It is independent of the 3proxy route and never touches the old
  `socks5-manager` / `socks5proxy` namespace (SPEC §4). The two are separate
  technical routes, not a migration.
- "Mixed, not pure SOCKS5" is a permanent property the protocol gate asserts on
  both protocols (SPEC §6). How the single outbound path is bounded is
  [ADR-0002](0002-literal-cidr-destination-boundary.md).
