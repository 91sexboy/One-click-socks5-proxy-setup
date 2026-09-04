# SPEC: Xray-only mixed proxy

## 1. Product

`socks5.sh` installs and manages one pinned Xray-core process. It does not install
3x-ui, a web panel, a database, a subscription service, or a second proxy engine.

The public inbound is Xray `protocol: "mixed"`. One TCP listener accepts both:

- SOCKS5 with RFC 1929 username/password authentication;
- HTTP proxy requests with Basic proxy authentication.

`mixed` is intentionally not a pure SOCKS5 listener. The client URI selects the
protocol it sends:

```text
socks5://user:password@host:port
http://user:password@host:port
```

The first release creates exactly one account and sets `udp: false`. TCP CONNECT
is supported. UDP ASSOCIATE, BIND, unauthenticated access, and invalid credentials
are rejected or fail closed.

## 2. Supported interaction

Every real invocation asks for language before command dispatch:

```text
1) 中文
2) English
```

Blank or `1` selects Chinese; `2` selects English; invalid input is retried with
a bounded count and EOF fails. Locale is process-only and never persisted.

A fresh install then asks for:

1. port — blank generates `20000–60000`; manual values are decimal,
   `1024–65535`, and observed free;
2. username — blank generates a value; manual values are `3–32` characters from
   `A-Za-z0-9_-`;
3. password — blank generates 32 characters; manual values are `12–128`
   characters from `A-Za-z0-9._~-` and are read once.

The password is visible while typed. `show` displays credentials only to root on
a real TTY. Redirected output never receives the credential card.

## 3. Xray release and runtime

The default release is the official stable Xray-core `v26.3.27`, tag commit
`d2758a023cd7f4174a5a5fa4ff66e487d4342ba0`.

| Architecture | Archive | Size | SHA-256 |
|---|---|---:|---|
| amd64 / x86_64 | `Xray-linux-64.zip` | 21136402 | `23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae` |
| arm64 / aarch64 | `Xray-linux-arm64-v8a.zip` | 19716427 | `4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c` |

Official Linux assets are architecture-oriented static binaries. The target
does not compile source code and does not receive Go, Git, GCC, Make, or headers.

The generated configuration has exactly one inbound and one direct outbound:

```json
{
  "log": {"loglevel": "warning", "access": "none", "error": ""},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 20000,
    "protocol": "mixed",
    "settings": {
      "auth": "password",
      "accounts": [{"user": "user", "pass": "password"}],
      "udp": false
    },
    "tag": "xray-mixed-in"
  }],
  "outbounds": [{"protocol": "freedom", "settings": {}, "tag": "direct"}]
}
```

No API, stats, metrics, routing, GeoIP, GeoSite, TLS, REALITY, WebSocket, gRPC,
XHTTP, or second public listener is configured.

Before publication or restart, the candidate is checked with:

```sh
xray run -test -c /path/to/candidate
```

The service runs:

```sh
xray run -c /etc/xray-socks5/config.json
```

Config-test does not bind a port. A successful config-test is followed by atomic
publication, service start, exact-listener readiness, and protocol verification.

## 4. Namespace and permissions

| Resource | Path | Expected owner/mode |
|---|---|---|
| Binary | `/usr/local/libexec/xray-socks5/xray` | `root:root 0755` |
| Config directory | `/etc/xray-socks5/` | root-owned, private |
| Config | `/etc/xray-socks5/config.json` | `root:xray-socks5 0640` |
| State | `/var/lib/xray-socks5/state` | `root:root 0600` |
| Transaction | `/var/lib/xray-socks5/transaction/` | root-owned, private |
| Lock | `/run/xray-socks5.lock` | root-owned |
| systemd | `/etc/systemd/system/xray-socks5.service` | `root:root 0644` |
| Account | `xray-socks5` | system, no home, `nologin`, no password |

The config is the only credential-bearing file. State contains no password. The
service command line and environment contain no password.

The Xray namespace is independent of the former 3proxy namespace. The script
never adopts, replaces, or removes old `socks5-manager` paths, units, or the
`socks5proxy` account.

## 5. Service contract

The service runs as the dedicated non-root account with `NoNewPrivileges`,
`ProtectHome`, `PrivateTmp`, restricted capabilities, and a read-only system
filesystem except for explicitly required paths. Xray config errors use exit
status 23; systemd prevents that status from entering an automatic restart loop.

Install, update, restart, and uninstall are serialized by an operation lock.
Status distinguishes service state from listener state. An active service is not
reported ready until the configured port is observed.

Updates use a complete restart rather than Xray gRPC hot update. Existing
connections may close during restart. A failed candidate config-test occurs
before stopping a healthy service and leaves the old config untouched.

The script never modifies host firewalls, cloud security groups, NAT, or port
forwarding. Runtime packages are not removed during uninstall.

## 6. Protocol and data-plane acceptance

Required CI cases:

- correct SOCKS5 RFC 1929 authentication and TCP CONNECT;
- wrong SOCKS5 authentication rejected;
- SOCKS5 no-auth offer rejected;
- correct HTTP Basic authentication and HTTP CONNECT;
- wrong HTTP authentication rejected;
- SOCKS4 and SOCKS4a do not establish a proxy connection;
- BIND rejected;
- UDP ASSOCIATE rejected while `udp=false`;
- IPv4 literal, hostname, and available IPv6 target paths recorded separately;
- one long-lived framed bidirectional tunnel;
- idle then resume on the same socket;
- one, 32, and 128 concurrent framed tunnels;
- no mid-stream EOF, RST, frame loss, reordering, or payload corruption.

Tests use a local target, monotonic deadlines, exact reads, unique connection IDs,
nonces, and sequence numbers. A successful handshake is never treated as proof
of a successful data plane.

## 7. Security requirements

- Download only over HTTPS with bounded response size.
- Verify archive size and SHA-256 before extraction.
- Inspect archive members and reject unsafe paths, links, devices, duplicates, and
  unexpected members; install only the verified `xray` executable.
- Set restrictive temporary-file permissions before writing credentials.
- Reject JSON injection through strict input validation.
- Keep credentials out of argv, environment, xtrace, logs, journal, and CI output.
- Fail closed on malformed state, external replacement, symlinks, changed account
  identity, unknown residual entries, or unobservable service state.
- Delete only fixed resources recorded for this Xray installation.

## 8. Verification and resource evidence

Complete verification runs in GitHub Actions. The workflow must have explicit
job timeouts and no `continue-on-error`. It must run unit tests under `sh`,
`dash`, and BusyBox `sh`, plus asset, config, protocol, lifecycle, secret, and
memory checks.

The initial memory job records evidence without claiming a universal minimum or
setting an unmeasured hard limit. It records Xray process `VmRSS`, service-cgroup
`memory.current`, `memory.peak`, OOM counters, restart count, startup time, and
separate idle/1/32/128-connection peaks. Target and driver processes stay outside
the Xray cgroup.

Documentation may publish a memory budget only with the Xray version, platform,
configuration, connection count, duration, and CI run that produced it.

The platform matrix carries its own evidence requirement. The platform check
accepts Ubuntu 22.04+ on amd64 and arm64, Ubuntu 20.04 on amd64, Debian 12+ and
CentOS Stream 9+. Acceptance is not evidence: the full service lifecycle is
exercised on Ubuntu 24.04 amd64 only, arm64 carries archive and binary
verification without a lifecycle job, and every other accepted target is
unverified. A successful archive download is never evidence that a
distribution's service lifecycle works. Non-systemd init systems are outside
this contract; see section 5.

Lifecycle verification includes crash recovery: the service is killed with
`SIGKILL` and must be restarted by systemd with the listener returning, and a
configuration error must exit 23 without entering a restart loop.

## 9. Non-goals

No 3x-ui, panel, database, API, subscription, QR code, multi-node deployment,
multiple-account UI, UDP enablement, TLS/REALITY, WebSocket, gRPC, XHTTP,
GeoIP/GeoSite, complex routing, automatic firewall changes, cloud API changes,
source compilation, custom Xray builds, legacy 3proxy migration, or unmeasured
`MemoryMax`.
