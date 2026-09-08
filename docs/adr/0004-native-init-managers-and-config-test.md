# ADR-0004: Native init managers, config-test before restart, no restart loop

## Status

Accepted. Implemented in the service contract of `socks5.sh` (SPEC §5, §8).

## Context

The proxy must run as a supervised, non-root service that survives a crash but
does not thrash on a bad configuration, on both the systemd and the Alpine/OpenRC
families this route supports.

## Decision

Run through the platform's **native** manager as the dedicated `xray-socks5`
account: a hardened systemd unit (`NoNewPrivileges`, `ProtectHome`, `PrivateTmp`,
restricted capabilities, read-only system paths, `RestartPreventExitStatus=23`),
or OpenRC `supervise-daemon` with `command_user`. Validate every candidate with
`xray run -test -c` **before** stopping a healthy service or publishing, and
require that a configuration error (exit 23) does not enter an automatic restart
loop on either backend. Serialize install/update/restart/uninstall with an
operation lock, and report ready only once the configured port is observed
listening. See SPEC §5.

## Alternatives considered

- **A custom supervisor / `nohup`-style daemon** — rejected: the native managers
  already provide supervision, boot integration, sandboxing, and log routing; a
  custom one would reimplement all of it, worse.
- **Restart on any exit** — rejected: a config error would then restart-loop; the
  exit-23 guard makes a bad config stop and stay stopped, surfacing the error.
- **gRPC hot update** — rejected for updates: a full restart is simpler to reason
  about and to verify; existing connections may close, which is acceptable
  (SPEC §5).
- **Assume the recorded port is owned** — rejected: ownership is verified through
  the listener check, so a foreign or unobservable listener on that port is
  refused (fail closed).

## Consequences

- Two backends mean two lifecycle gates in CI (the systemd and OpenRC integration
  jobs), which are the authority for service behaviour; unit tests stub the
  managers. The backend decision is centralized in `s5_svc <verb>`.
- config-test-before-restart, plus the operation lock, plus the transaction
  rollback copies (SPEC §5) together make a failed update leave the running
  service and the published config untouched.
