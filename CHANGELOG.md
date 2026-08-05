# Changelog

Notable user-facing changes to claude-code-dock. This project doesn't use a
versioned release cadence yet — `:latest` moves on every push to `main` and
on a manually triggered `workflow_dispatch` run (see
`.github/workflows/docker-publish.yml`), so entries here are dated rather
than numbered. Check this file before running `./scripts/update.sh` if you
want to know what's actually changing.

## Unreleased

### Added
- `SHARED_CREDENTIALS_PATH`: optional host directory that lets several
  sessions reuse one Claude Code login instead of each `REMOTE_SESSION_NAME`
  needing its own (which was, and remains, the default). Same
  `/dev/null`-fallback idiom as `GITHUB_TOKEN_FILE`/`GLOBAL_CONFIG_PATH` — a
  no-op unless set. Doesn't need to exist beforehand (created empty on first
  use, unlike a single-file mount). `~/.claude/.credentials.json` is
  symlinked into it at startup, so a login performed at any point during that
  session's runtime — not just one already present at container start — and
  any later token rotation both write straight through, with no restart
  needed and no risk of a stale copy shadowing a real login.
  `scripts/backup.sh` dereferences this symlink into a real file before
  taring `CONFIG_DIR`, so a session's backup archive still contains the
  actual credential bytes instead of a link `tar` would otherwise store as
  just a target path — `restore.sh` needed no changes, since the restored
  archive already has a plain file at the usual path.
  See [docs/docker.md](docs/docker.md#claude-code-dock-volumes).
- `GLOBAL_CONFIG_PATH` now also links a `skills/` subdirectory into
  `~/.claude/skills/` at startup, mirroring the existing `commands/` handling
  (one symlink per skill directory, no merge step — same idiom `CLAUDE.md`'s
  merge-with-`CLAUDE-local.md` doesn't need since there's nothing to combine).
- `INSTANCE_CONFIG_PATH`: optional, additive override of the
  `CONFIG_BASE_PATH`/`REMOTE_SESSION_NAME` join — an explicit path to this
  instance's config directory, used directly when set. Unset, every script
  (`docker-compose.yml`'s volume mount, `backup.sh`, `restore.sh`,
  `status.sh`, `new-session.sh`) resolves the config directory exactly as
  before this variable existed. `new-session.sh` clears an inherited
  `INSTANCE_CONFIG_PATH` when copying a `.env` as a template for a new
  session, rather than pointing the new session at the same directory as
  the one it was copied from.
- `SHARED_CREDENTIALS_MODE=seed`: opt-in alternative to
  `SHARED_CREDENTIALS_PATH`'s original live symlink+background-poller
  mechanism (still the `live` default, completely unchanged). `seed` copies
  a shared login into a session's own credentials file once, at boot — no
  live link, no poller, and no automatic promotion in the other direction.
  Promoting a session's own login into the shared pool is now a separate,
  explicit, host-side command: `./scripts/promote-credentials.sh
  [session-name]`. Exists specifically to avoid a no-locking race in `live`
  mode: since `live` mode's link is *live*, not a one-time copy, two
  sessions promoting near-simultaneously can silently overwrite each
  other's login for every already-linked session, not just new ones. See
  [docs/docker.md](docs/docker.md#shared-credentials-mode).
- `backups/<REMOTE_SESSION_NAME>/`: `scripts/backup.sh` now writes into a
  per-instance subfolder by default once a session name is known, instead
  of one flat `./backups/` directory shared by every session.
  `--output DIR` always wins outright (no subfolder appended). An
  unnamed/default session keeps the flat layout. `scripts/restore.sh`
  (`--list` and the default "most recent backup" resolution) checks **both**
  locations, so backups taken before this change stay listable and
  restorable with no migration step.
- [docs/usage-patterns.md](docs/usage-patterns.md): generic worked examples
  for a Git-versioned project, a local workspace with no Git, and a
  multi-project workspace — all already fully supported today, since
  `GIT_REPO_URL`/`GITHUB_TOKEN_FILE`/`GIT_USER_NAME`/`GIT_USER_EMAIL` were
  already independent and optional. No new variable needed.
- [docs/git-integration.md](docs/git-integration.md): documented pointing
  several sessions' `GITHUB_TOKEN_FILE` at the same shared token file as a
  first-class supported pattern (alongside the existing per-instance
  pattern) — no code change, `GITHUB_TOKEN_FILE` was already just an
  arbitrary host path.
- [docs/docker.md](docs/docker.md#recommended-layout-for-several-instances):
  a recommended `shared/`/`instances/`/`backups/` directory layout tying
  `INSTANCE_CONFIG_PATH`, `SHARED_CREDENTIALS_PATH`, `GITHUB_TOKEN_FILE`,
  and `GLOBAL_CONFIG_PATH` together for operators running more than a
  couple of instances.

### Fixed
- `docs/getting-started.md` incorrectly claimed that pointing multiple
  sessions at the same `CONFIG_BASE_PATH` was enough to share one Claude Code
  login across them ("all containers point here, you log in only once").
  That was never true — `REMOTE_SESSION_NAME` gets its own isolated
  subfolder under `CONFIG_BASE_PATH` regardless, so each session always
  needed its own login. Corrected, and now points to the new
  `SHARED_CREDENTIALS_PATH` variable above for anyone who actually wants
  that behavior.

### Changed
- `scripts/backup.sh`/`restore.sh`/`status.sh` now share one path-resolution
  helper (`scripts/lib/config-path.sh`) instead of each having its own
  copy-pasted `CONFIG_BASE_PATH`/`REMOTE_SESSION_NAME` join logic with
  subtly different edge-case handling.
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
