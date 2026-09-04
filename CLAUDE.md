# CLAUDE.md

## Agent skills

### Issue tracker

Issues live as GitHub issues on `91sexboy/One-click-socks5-proxy-setup`, managed
with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical roles, using their default label strings
(`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`).
See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root (neither exists
yet; skills create them lazily). See `docs/agents/domain.md`.

## Testing workflow

- Run the complete test suite in GitHub Actions by default; do not run the full
  local `tests/run.sh` suite because it is slow.
- Local checks should be limited to fast syntax checks or targeted tests, such as
  `sh -n socks5.sh`, `dash -n socks5.sh`, `busybox sh -n socks5.sh`, or one unit
  test file when investigating a focused change.
- Do not push without explicit user authorization. When authorized, push the
  branch and use the required GitHub Actions jobs as the complete test result.
- Do not report testing as complete until all required CI jobs have passed.
