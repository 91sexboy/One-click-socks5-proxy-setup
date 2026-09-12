# CONTEXT

Domain glossary and orientation for the **Xray-only mixed proxy** route
(`socks5.sh`). Read this before exploring; it fixes the vocabulary the code,
tests, commits, and issues use.

- `SPEC.md` is the behavioural contract — the **what**.
- `docs/adr/` records the decisions behind it — the **why**.
- This route is independent of the `develop` route: they are separate technical
  directions, not a base/branch pair, and are never merged into each other.

## Glossary

Use these terms as defined here; don't drift to synonyms.

**mixed inbound** — the single Xray `protocol: "mixed"` TCP listener. One port
accepts both SOCKS5 (RFC 1929 user/pass) and HTTP-proxy (Basic) auth; the client
URI scheme picks which. Deliberately not a pure SOCKS5 listener. (SPEC §1,
[ADR-0001](docs/adr/0001-xray-only-mixed-proxy.md).)

**destination boundary** — the twelve reserved/special IP ranges the engine
blackholes (the `blocked` outbound), so an authenticated client cannot reach the
proxy host's own loopback/private/CGNAT/link-local space or unrouteable ranges.
Breaching it is a release blocker. (SPEC §3,
[ADR-0002](docs/adr/0002-literal-cidr-destination-boundary.md).)

**advertise-safety check** — `s5_ipv4_is_public`: decides whether a detected
address is safe to print on the credential card. A *separate* concern from the
destination boundary — different set, different purpose — reconciled with
neither, and cross-referenced in code so the two are not mistaken for one.

**credential card** — the terminal-only connection details shown after a successful
install or update, and available again through `show` (root only). Names the
server, port, and account, using the server's own public IPv4 or the literal
`SERVER_IPV4` placeholder. (SPEC §2.)

**language preference** — the operator's saved Chinese or English choice, reused
across commands until explicitly changed. Independent of the proxy installation;
uninstalling the proxy does not discard the preference. (SPEC §2.)

**pinned release / pinned binary** — the exact Xray version and tag commit, plus
the per-architecture archive and extracted-`xray` sizes and SHA-256s, that every
command verifies. A wrong value refuses every install on that architecture.
(SPEC §3, [ADR-0003](docs/adr/0003-pinned-verified-prebuilt-release.md).)

**state** — `/var/lib/xray-socks5/state` (`0600`): the record of the installation
(release, pins, port, username, account ids, config/unit hashes). Loaded and
re-verified on every command; contains no password.

**transaction** — the `0600` rollback copies of the previous config and state kept
under the state directory during an update; the way back only once a new config
has actually been published. (SPEC §5.)

**operation lock** — `/run/xray-socks5.lock`: serialises install / update /
restart / uninstall. (SPEC §4–5.)

**config-test** — `xray run -test -c <candidate>`, run before any publish or
restart; it does not bind a port. A failed test never stops a healthy service or
replaces the published config. (SPEC §3, §5,
[ADR-0004](docs/adr/0004-native-init-managers-and-config-test.md).)

**service state vs listener state** — status distinguishes "the manager thinks it
is running" from "the configured port is actually observed listening". An active
service is not reported ready until the port is observed. (SPEC §5.)

**in-place update** — re-running install over an existing install: rotates
port/username/password through a full restart (not gRPC hot update), keeping the
port the service already owns. (SPEC §5.)

**fail closed** — on malformed state, external replacement, symlinks, a changed
account identity, unknown residue, or unobservable service state, the command
refuses rather than proceeding. (SPEC §7.)

**the two backends** — systemd (a hardened unit with `RestartPreventExitStatus=23`)
and OpenRC `supervise-daemon` on Alpine 3.20+. The backend decision is made in one
place, `s5_svc <verb>`. (SPEC §5,
[ADR-0004](docs/adr/0004-native-init-managers-and-config-test.md).)

**exit 23** — the configuration-error exit status Xray returns; both backends must
treat it as "do not enter a restart loop". (SPEC §5, §8.)

**namespace** — the `xray-socks5` account, paths, and units. Independent of the
former 3proxy `socks5-manager` / `socks5proxy` namespace, which this route never
adopts, replaces, or removes. (SPEC §4,
[ADR-0001](docs/adr/0001-xray-only-mixed-proxy.md).)

**data-plane acceptance / mixed gate** — the CI protocol probe under
`tests/protocol/` that drives real framed tunnels through the running proxy and
emits `mixed_*=ok` markers a shell gate requires. A successful handshake is never
treated as proof of a working data plane. (SPEC §6.)

**lifecycle gate** — the per-backend integration script
(`.github/scripts/{systemd,alpine}-lifecycle.sh`, shared fixtures in
`lifecycle-common.sh`) that exercises install → … → uninstall against the real
init system in CI. (SPEC §8.)
