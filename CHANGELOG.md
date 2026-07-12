# Changelog

Notable user-facing changes to claude-code-dock. This project doesn't use a
versioned release cadence yet — `:latest` moves on every push to `main` and
on a manually triggered `workflow_dispatch` run (see
`.github/workflows/docker-publish.yml`), so entries here are dated rather
than numbered. Check this file before running `./scripts/update.sh` if you
want to know what's actually changing.

## Unreleased

### Added
- `SHARED_CREDENTIALS_FILE`: optional host file that lets several sessions
  reuse one Claude Code login instead of each `REMOTE_SESSION_NAME` needing
  its own (which was, and remains, the default). Same `/dev/null`-fallback
  idiom as `GITHUB_TOKEN_FILE`/`GLOBAL_CONFIG_PATH` — a no-op unless set. The
  first session to log in seeds the file; every session started afterward
  loads from it instead of prompting for login. One-time sync at container
  startup, not a live/continuous share. See
  [docs/docker.md](docs/docker.md#claude-code-dock-volumes).
- `GLOBAL_CONFIG_PATH` now also links a `skills/` subdirectory into
  `~/.claude/skills/` at startup, mirroring the existing `commands/` handling
  (one symlink per skill directory, no merge step — same idiom `CLAUDE.md`'s
  merge-with-`CLAUDE-local.md` doesn't need since there's nothing to combine).

### Fixed
- `docs/getting-started.md` incorrectly claimed that pointing multiple
  sessions at the same `CONFIG_BASE_PATH` was enough to share one Claude Code
  login across them ("all containers point here, you log in only once").
  That was never true — `REMOTE_SESSION_NAME` gets its own isolated
  subfolder under `CONFIG_BASE_PATH` regardless, so each session always
  needed its own login. Corrected, and now points to the new
  `SHARED_CREDENTIALS_FILE` variable above for anyone who actually wants
  that behavior.

### Changed
- **Breaking:** `SHARED_CONFIG_PATH` renamed to `GLOBAL_CONFIG_PATH` (mount
  target inside the container also renamed, from `~/.claude-shared` to
  `~/.claude-global`). "Shared" didn't distinguish this mount from every
  other bind mount in the project, which are all shared between host and
  container by definition — "global" matches the actual meaning (applied to
  every session) and Claude Code's own user-level-vs-project-level `CLAUDE.md`
  vocabulary. If you already set `SHARED_CONFIG_PATH` in `.env`, rename it to
  `GLOBAL_CONFIG_PATH` before updating.
- `scripts/watchdog.sh` now auto-discovers every `claude-code-dock*`
  container on the host (same filter `scripts/sessions.sh` uses) when run
  with no container name and no `CONTAINER_NAME` already set in its process
  environment — one `./scripts/install.sh --with-watchdog` crontab entry now
  covers every session from `new-session.sh`/`session-up.sh`, including ones
  created after the entry was installed, instead of only the first session.
  `CONTAINER_NAME` sourced from `.env` no longer silently pins single-container
  mode (it's captured before `.env` is read), since `.env` almost always
  defines it for `docker compose`'s own purposes and would otherwise defeat
  auto-discovery for exactly the multi-session hosts it's meant to help.
  Explicit single-container use (`watchdog.sh <name>`, or `CONTAINER_NAME=foo`
  already set before the script starts) is unchanged.
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

### Changed
- `docker-publish.yml` no longer rebuilds `:latest` on a weekly cron. A
  rebuild now only happens on a push to `main` or an explicit manual
  `workflow_dispatch` run — run the workflow by hand when you want to pull in
  a new `@anthropic-ai/claude-code` release that isn't tied to a
  claude-code-dock commit.

### Removed
- `CLAUDE_AUTO_APPROVE` and all logic built around it (`settings.json`
  patching, `install.sh`/`session-up.sh`'s resource-limit safety
  confirmation, `entrypoint.sh`'s startup warning, `status.sh`'s
  auto-approve row) — it wasn't reliably applying
  `--dangerously-skip-permissions` in practice, and `CLAUDE_EXTRA_ARGS`
  already covers passing that flag through explicitly, so there's no need
  for a second, narrower mechanism to keep in sync with it.

## Before this file existed

See `git log` and `CLAUDE.md`'s own Roadmap section for the fuller history —
this file starts tracking from here forward.
