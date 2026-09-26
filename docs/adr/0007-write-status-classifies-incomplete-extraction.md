# ADR-0007: Writer status classifies incomplete extraction

## Status

Accepted. Supersedes the failure-classification part of
[ADR-0006](0006-storage-failure-is-not-artifact-failure.md); its advisory capacity
preflight and observed-byte diagnostics remain accepted.

## Context

A quota-limited Alpine 3.22 LXD container reproduced the original failure with a
more precise signal. The filesystem reported about 39.2 GiB free through
`statfs`, but writing the extracted Xray member stopped at 7,798,784 of
36,577,406 bytes with `EDQUOT`. `/usr/bin/unzip -p` returned zero, wrote no
stderr, and left the short file. The capacity estimate therefore looked healthy
while the actual write failed.

ADR-0006 concluded that filesystem free space was the signal that separated an
incomplete write from wrong artifact bytes. That premise does not hold for
project, volume, or user quotas that are enforced by `write(2)` but are absent
from the filesystem-wide free-block count. A post-hoc size check cannot recover
the missing writer status, and localized errno text is not a stable interface.

Extraction also has two independently meaningful outcomes. The archive producer
can fail while a consumer exits successfully, and the consumer can fail while a
producer sees only the resulting closed pipe. A normal POSIX pipeline exposes
only its last command's status without non-portable `pipefail`, so
`unzip | cat >file` cannot meet the contract on POSIX `sh`, dash, and BusyBox sh.

Finally, staging temporarily makes the install prefix private. Failure recovery
cannot apply one message and one action to both a prefix created by this operation
and a verified installation that existed before it.

## Decision

Treat command completion, not inferred capacity, as the evidence for transfer
failure.

- Keep the capacity check as an advisory preflight that can reject an obviously
  undersized filesystem. Never use its answer to classify a later short file.
- Extract through a controlled transport whose producer and writer statuses are
  saved separately. The trusted producer remains the absolute-path,
  environment-cleared `s5_unzip` seam. A narrow writer seam copies standard input
  to the candidate file and is injectable by focused tests.
- A writer failure is `disk.write`, with observed and expected byte counts. It
  takes precedence over a producer failure caused by the writer closing its input.
  A producer-only failure is `asset.invalid extract`.
- Only producer success plus writer success reaches exact size, SHA-256, ELF
  architecture, and publication checks. If both report success but the size is
  wrong, keep `asset.size`; do not invent `ENOSPC` or `EDQUOT`.
- The controlled transport and candidate are owned by the staging work directory.
  Success, failure, and handled-signal paths reap the producer and remove transport
  objects and partial candidates.
- Release staging storage before restoring an existing prefix's required `0755`
  mode. Preserve the original staging status; cleanup failure cannot suppress it
  or prevent the restore attempt, and both failures remain diagnosable.
- On a fresh install, a staging failure leaves the newly created prefix private
  until unified cleanup removes the new namespace and does not emit the warning
  reserved for a damaged existing installation. On an update, preserve the old
  contents and attempt mode restoration.

## Alternatives considered

- **Classify a short file from `statfs` after extraction** — rejected: the
  reproduced `EDQUOT` occurred while `statfs` still reported tens of GiB free.
- **Parse the writer's stderr for `ENOSPC` or `EDQUOT`** — rejected: errno text is
  localized, command-dependent, and not an interface. The nonzero writer status
  is sufficient; the byte counts make the incomplete write diagnosable.
- **Use `unzip | cat >file`** — rejected: portable POSIX shells expose only the
  last command's status, so producer failure can be hidden, while `pipefail` is
  unavailable in dash and BusyBox sh.
- **Use exact size alone** — rejected: it detects incomplete bytes but cannot say
  whether the producer supplied the wrong stream or the writer failed, which is
  the distinction the operator needs.
- **Restore prefix mode before deleting staging** — rejected: on a quota-limited
  host, staging itself consumes the quota needed for metadata or recovery work.
- **Always warn that the service account lost access** — rejected: a fresh install
  has no prior usable installation to damage and unified cleanup removes its new
  namespace.

## Consequences

- The exact 7,798,784 / 36,577,406 quota failure is reported as an incomplete
  storage write even when free-space preflight reports ample capacity.
- Extractor failures, writer failures, successful transfers with wrong size,
  wrong SHA-256, and wrong architecture retain independent acceptance gates and
  diagnostics.
- Extraction needs a controlled POSIX transport and explicit producer reaping,
  which adds internal implementation but keeps the external staging interface
  unchanged.
- Tests can inject a deterministic short writer without depending on a particular
  LXD storage backend or English error output.
- Fresh-install cleanup removes the new namespace without a misleading existing-
  installation warning; update cleanup preserves the old installation and makes
  restoring its accessible mode the recovery priority after releasing staging.
