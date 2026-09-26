# ADR-0006: A storage failure is reported as storage, not as a bad artifact

## Status

Accepted in part. The advisory capacity preflight and observed-byte diagnostics
remain accepted. [ADR-0007](0007-write-status-classifies-incomplete-extraction.md)
supersedes this ADR's premise that filesystem free space can classify a later
short write.

## Context

An Alpine 3.22 LXD container reported this:

```text
[x] Xray 资产校验失败：binary-size。
chmod: changing permissions of '/usr/local/libexec/xray-socks5': Quota exceeded
```

The container was out of disk quota. Nothing was wrong with the artifact: the
archive had already been accepted at its pinned byte size and SHA-256, and the
member listing had passed. The extraction then wrote a short file, the pinned
size gate refused it, and the installer told the operator that Xray asset
verification had failed — the same wording it uses for bytes that are not the
pinned release.

That wording is what makes the failure undiagnosable, and it has now cost two
investigations. [ADR-0005](0005-pinned-verification-toolchain.md) records the
first: another Alpine 3.22 host reported `binary-size` for a genuinely different
reason (an Info-ZIP option variable rewriting line endings inside the executable),
and its reasoning — reaching the extracted-binary gate proves the accepted archive
"had been extracted into different bytes" — reads as if the toolchain were the
only candidate. On a full filesystem that conclusion is wrong.

Three measurements, taken against the real code, fix the shape of the problem:

- On a 12 MiB filesystem with a 30 MiB pinned member, `/usr/bin/unzip -p` **exits
  0** and leaves a truncated file. The `|| s5_msg_err asset.invalid extract` branch
  is never taken, so the size gate is where a full disk becomes visible, and the
  size gate is exactly where the message says "asset".
- The hostile `UNZIP=-aa` case of ADR-0005 also exits 0 and also leaves a file
  **shorter** than its pin (87 bytes became 85). So the direction of a size
  mismatch does not identify either cause: short means both.
- `chmod` on the prefix can fail with `EDQUOT` on a quota-limited filesystem. The
  restore of the documented `0755` then leaves the prefix at `0700`, and
  `s5_verify_installed_artifacts` holds that directory to exactly `0755` as part of
  installed identity — so every later command, `uninstall` included, refuses until
  the mode is put back by hand. The installer said none of that: only chmod's own
  untranslated line, with no statement of what it meant.

This ADR originally concluded that the filesystem's free-space answer separated a
write that could not complete from bytes that were never right. A later exact
`EDQUOT` reproduction disproved that premise: quota enforcement can reject the
write while filesystem-wide free blocks remain ample. ADR-0007 records the
replacement decision based on producer and writer command status.

## Decision

The capacity-preflight and observed-byte parts below remain historical context and
accepted behavior. The post-write classification rule is superseded by ADR-0007:
a failed writer is direct storage-failure evidence, while a successful transfer
with the wrong size remains an artifact-size failure regardless of `statfs`.

Ask the filesystem before staging, and report the numbers.

- **Refuse up front when there is no room.** Staging checks, after the work
  directory exists and before the download starts, that there is room for the three
  files that exist at once: the archive and the extracted member in the work
  directory, and the published copy under the prefix. When both paths report the
  same filesystem — one root filesystem, which is where this was reported — the
  requirement is their sum, because two per-path checks would both pass on a host
  that cannot hold all three. `stat -c '%d'` answers which filesystem a path is on,
  and two paths reporting the same id draw on the same free space. The update path
  checks the transaction directory before copying the live binary into it.
- **Let the size gates report what they observed.** `s5_accept_size` is the one
  gate used for both the archive and the extracted member. It names the length it
  saw and the length it wanted, so two bytes short (a rewritten stream) and twenty
  megabytes short (a write that ran out of room) are distinguishable in a bug
  report without a rerun.
- **Name the cause the filesystem can confirm.** A mismatch is reported as a write
  that could not complete only when the file is *shorter* than its pin **and** the
  filesystem is out of room. Both conditions are required: a file longer than its
  pin is something no truncation produces — a length-less response admitted one byte
  over the bound, or a tampered member — so offering the disk as its explanation
  would reinstate the mirror image of the misdiagnosis this ADR removes. Otherwise
  the artifact reason stands.
- **Report a failed mode restore.** A prefix left private is stated in the
  operator's language, naming the mode the installation contract requires, the
  service account that loses access, and the fact that later commands refuse until
  it is restored. Refusing is deliberate — the mode is installed identity, and this
  route fails closed — so what the message adds is the way out.

Both answers come from `stat` — `stat -f -c '%f %S'` for free space and
`stat -c '%d'` for filesystem identity — reached the way `s5_path_contract` already
reaches `stat`, and `stat` is in the precheck list every command requires. `df` is
not used and never was required. What `stat` reports is the filesystem's free
blocks, which is what root can actually write; `df`'s Available column is the
narrower figure available to unprivileged users, and every command that stages an
engine runs as root. The free count is in fundamental blocks, so an unrecognised
block size is treated as no answer rather than converted by guess.

Capacity remains advisory, never an acceptance gate: every unusable answer leaves
the operation alone instead of refusing a working host, and the pinned size and
SHA-256 remain the only authority over what gets installed. A wrong capacity answer
can therefore cost a false refusal or a useless pass, never an unverified binary.

## Alternatives considered

- **Treat a short file as a full disk** — rejected: the `-aa` case of ADR-0005 is
  also short, so this would report "the filesystem is full or over quota" for a
  substituted extractor, trading one misdiagnosis for its mirror image.
- **Check free space only, and leave the gate messages alone** — rejected: the
  preflight cannot cover space that runs out after it passes, or a per-user quota
  that `statfs` does not report, and those residual cases are exactly the ones a
  maintainer reads about second-hand. The observed byte count is what makes them
  diagnosable.
- **Refuse when the filesystem cannot answer** — rejected: it converts an unknown
  into a failed install on filesystems that report nothing usable, for a check whose
  only job is to explain a failure earlier than the authoritative gates would.
- **Read `df`'s Available column** — rejected: it reports the space available to
  unprivileged users and excludes the reserve only root may write into, while every
  staging command runs as root. On the development host `stat -f /` gives 9809341
  free blocks against 8763274 available at 4096 bytes — a 4.0 GiB gap. A nearly full
  ext4 root whose unprivileged figure has dropped below the requirement would be
  refused outright although root could complete the install, and a false refusal on
  a working host is the one outcome this check must never produce.
- **Decide same-filesystem by whole-row `df` equality** — rejected: the row carries
  Used, Available and Capacity, which move between the two calls, so one filesystem
  compares unequal to itself while anything else on the host is writing. Two paths
  on one filesystem compared unequal 160 times out of 300 under modest write churn,
  which silently drops the combined requirement back to the per-path checks —
  exactly on the busy single-filesystem container the branch exists for. A
  filesystem id cannot move that way.
- **Always sum every requirement against the smallest free space** — rejected: the
  work directory and the prefix are frequently on different filesystems, and that
  refuses hosts with ample room on each for what it is actually asked to store. The
  sum is required only once the filesystems are known to be the same one.
- **Fail closed on the raw `chmod` line alone** — rejected: it is untranslated,
  arrives in the middle of localised output, and states an errno rather than the
  consequence. It is kept, because the errno is what identified this failure, but
  it is no longer the only thing the operator gets.

## Consequences

- A host without room is refused before 21 MB is fetched, and the refusal names
  the filesystem, the requirement and what is available. On one root filesystem the
  requirement is the full 90 MiB the install actually needs, not the 55 MiB of one
  stage.
- A size mismatch now always reports both byte counts, so `binary-size` alone can
  no longer send an investigation after the wrong cause.
- No new command is required. `stat` is already required by every command, so the
  skipped-check path covers an unrecognised block size or a path `stat` cannot
  reach, not a missing tool. BusyBox supports both `stat -f -c '%f %S'` and
  `stat -c '%d'`, so the Alpine path is not inert.
- A file longer than its pin is never attributed to storage, so the artifact refusal
  keeps its own meaning in both directions.
- The extract gate keeps its own reason for an extractor that fails outright, and
  the archive gate keeps its upper bound for a length-less response, so neither of
  the pinned gates is relaxed by any of this.
- `tests/unit/test_xray_asset.sh` drives the capacity seams directly: no room
  refuses before the download, one filesystem is asked for the sum of all three
  files, a short file with a full filesystem reports the write, the same short file
  with room available still reports the artifact and its numbers, a file longer than
  its pin stays an artifact refusal, and a filesystem that answers nothing usable
  still installs.
