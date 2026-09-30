# ADR-0008: Target systems install verified raw Xray Release assets

## Status

Accepted. Supersedes the target-side ZIP acquisition and extraction portions of
[ADR-0003](0003-pinned-verified-prebuilt-release.md),
[ADR-0005](0005-pinned-verification-toolchain.md),
[ADR-0006](0006-storage-failure-is-not-artifact-failure.md), and
[ADR-0007](0007-write-status-classifies-incomplete-extraction.md). Their historical
failure evidence remains valid.

## Context

The ZIP-era target path held the 19–20 MiB archive, a 33–35 MiB extracted
executable and a second publication copy at once. Fresh installation therefore
needed approximately 84–90 MiB even though the final installation retained only
one executable. This was material on quota-limited Alpine containers.

The repository can reproduce the unchanged `xray` members from pinned official
ZIPs in CI, verify their provenance there, and publish the exact members as
architecture-specific Release assets.

## Decision

Publish raw executables under a revisioned distribution tag independent of the
upstream Xray version. For v26.3.27 the distribution is
`xray-v26.3.27-r1`, containing raw amd64 and arm64 executables, SHA256SUMS,
machine-readable provenance and the exact upstream license. The older ZIP
Release remains available for older installer revisions.

The target installer downloads the selected raw executable directly into a
private `.xray.*` file under `/usr/local/libexec/xray-socks5`. Before publication
it verifies exact size and SHA-256, ELF architecture, absence of dynamic linkage,
and the reported Xray version. It then applies final ownership/mode and atomically
renames the same file to `xray`; no extracted or publication copy exists.

Fresh capacity therefore requires one candidate: 35,721 KiB on amd64 or 33,409
KiB on arm64. A binary-changing update additionally retains `old.xray` until the
new config, service, dataplane and state commit succeed. On a shared filesystem
that normal update path needs the old binary plus the new candidate.

New raw installations write state schema 2. Existing schema-1/legacy ZIP state
remains readable and keeps its real ZIP provenance during configuration-only
updates. A successful binary replacement migrates the installation to schema 2;
rollback restores the exact previous state.

## Consequences

- Target systems no longer require Info-ZIP or `unzip`.
- Archive member safety moves to the reproducible publisher and native asset CI.
- Curl status 23 remains direct storage-write evidence; a successful response
  with wrong length or digest remains an artifact-identity failure.
- A hard crash can leave a private `.xray.*` candidate, while handled failures
  and signals remove invocation-owned candidates.
- The Release publisher and CI must preserve raw/source pins and prove the raw
  asset equals the verified official ZIP member byte for byte.
- Publication is resumable. The assembled payload is fixed by the commit (the
  workflow run is named in the release notes, not the provenance record), and
  assets upload executables first and the checksum and provenance records last.
  If a dispatch stops part way, dispatch the workflow again from the same
  `xray-only` commit: it finds the same draft, keeps every byte-identical
  uploaded asset, replaces an asset whose upload never completed, refuses any
  uploaded asset whose bytes differ, and publishes only after the downloaded
  assets match the assembled payload and their checksum file. A published
  release, or a tag on another commit, is never altered.
