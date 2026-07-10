# Changelog

Notable user-facing changes to claude-code-dock. This project doesn't use a
versioned release cadence yet — `:latest` moves on every push to `main` and
on a weekly rebuild (see `.github/workflows/docker-publish.yml`), so entries
here are dated rather than numbered. Check this file before running
`./scripts/update.sh` if you want to know what's actually changing.

## Unreleased

### Added
- `docker/entrypoint.sh` / `docker/claude-remote-launch.sh` now log how long
  each startup step took, a one-line summary (mode, container name, session),
  and — persisted to `~/.claude/logs/dock.log`, which survives `tmux` taking
  over the terminal — an explicit "ACTION REQUIRED" block naming the exact
  `docker exec ... tmux attach-session -t main` command to run when a first
  login or Remote Control pairing is still pending.
- CI: a `docker compose config` step validates `docker-compose.yml` and the
  opt-in `docker-compose.resources.yml` overlay parse and resolve correctly —
  nothing previously exercised the compose file itself.
- Removed the opt-in watchdog sidecar (`docker-compose.watchdog.yml`) — it
  mounted `/var/run/docker.sock` (root-equivalent host access) to solve
  exactly what `./scripts/install.sh --with-watchdog`'s host crontab already
  solves without that exposure. The crontab path is now the only way to
  schedule `scripts/watchdog.sh`.
- CI (`tests/smoke.sh`): now also boots a container via a real
  `docker compose up` (not just `docker run`), asserting the main service
  reaches `healthy`.
- CI (`tests/smoke.sh`): an end-to-end disaster-recovery drill — runs the
  real `scripts/backup.sh` and `scripts/restore.sh` against fake credentials,
  wipes the config directory, restores it, boots a container against the
  restored data, and confirms from `dock.log` that it's recognized as
  already-authenticated rather than prompting for a fresh login.
- `scripts/update.sh` now waits for Docker's `HEALTHCHECK` to report
  `healthy` (not just that the container is `Running`) after updating, and
  automatically rolls back to the previous image if it doesn't — re-tagging
  the prior image and recreating, before any dangling-image cleanup can
  remove it. Exits non-zero even when the rollback itself succeeds, since
  the requested update still failed.
- `tzdata` added to the image — `TZ` previously only affected the startup
  banner's own text, not the actual timestamps in `dock.log`, since the
  zoneinfo database it depends on wasn't installed.

### Fixed
- `scripts/session-up.sh` now runs the same `CLAUDE_AUTO_APPROVE=true`
  safety confirmation `scripts/install.sh` already had — previously, every
  session started via `new-session.sh` + `session-up.sh` skipped it
  entirely, no matter how many had auto-approve on with no resource limits.

## Before this file existed

See `git log` and `CLAUDE.md`'s own Roadmap section for the fuller history —
this file starts tracking from here forward.
