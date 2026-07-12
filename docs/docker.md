# Docker Reference — claude-code-dock

For Docker commands reference, see this document. For architecture details, see [Architecture](architecture.md). For troubleshooting, see [Troubleshooting Guide](troubleshooting.md).

## Core Concepts

Before using claude-code-dock, it helps to understand how Docker containers behave in this project.

### Container as a "Persistent Server"

In many projects, containers are ephemeral — created, used, and discarded. In claude-code-dock, the container is treated as a persistent server, similar to a system service:

```
Conventional server:       claude-code-dock:
+------------------+       +------------------------------+
|  systemd service |       |  Docker container            |
|  nginx (PID 1)   |  ~=   |  tmux (PID 1)                |
|  Auto restart    |       |  restart: unless-stopped     |
|  Persistent logs |       |  Persistent volumes          |
+------------------+       +------------------------------+
```

### How tmux fits in

Claude Code runs inside a tmux session named `main`. tmux is the container's PID 1. This means:

- `docker exec -it --user node claude-code-dock tmux attach-session -t main` connects to the running Claude session
- `Ctrl+B D` detaches from the session without killing Claude
- `docker exec -it --user node claude-code-dock bash` opens a separate shell for inspection, without touching Claude

---

## Essential Operations

### Start the container

```bash
# Start in background (daemon mode)
docker compose up -d

# Start and watch initialization logs
docker compose up
```

### Connect to Claude Code

```bash
# Recommended method: attach.sh
./scripts/attach.sh

# Or directly:
docker exec -it --user node claude-code-dock tmux attach-session -t main

# To disconnect WITHOUT stopping Claude:
# Press Ctrl+B then D
```

**Why `tmux attach-session` and not `docker attach`?**

Claude Code runs inside a tmux session named `main`. The container's PID 1 is `tmux`. `docker exec -it --user node ... tmux attach-session -t main` connects to the existing session where Claude is running.

`docker exec -it --user node ... bash` opens a new separate shell, useful for inspection but not for using Claude directly.

### Disconnect without stopping

```
Ctrl+B  then  D
```

This key sequence instructs tmux to detach the client from the session **without terminating the process**. Claude Code keeps running normally in the `main` session.

### Stop the container (intentional)

```bash
# Stop gracefully (Claude receives SIGTERM via tmux)
docker compose stop

# Stop and remove container (preserves volumes)
docker compose down

# Stop and remove including anonymous volumes (does NOT remove bind mounts)
docker compose down -v
```

### Restart

```bash
# Restart the container
docker compose restart

# Forced restart after .env change
docker compose up -d --force-recreate
```

---

## Volume Management

### claude-code-dock volumes

The project uses five volumes:

```yaml
volumes:
  - ${WORKSPACE_PATH}:/workspace                                     # User projects
  - ${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}:/home/node/.claude     # Claude Code credentials (per-session)
  - ${GLOBAL_CONFIG_PATH:-/dev/null}:/home/node/.claude-global:ro     # Optional: global CLAUDE.md/commands/skills (or /dev/null, a no-op)
  - ${GITHUB_TOKEN_FILE:-/dev/null}:/run/secrets/github_token:ro      # Optional: GitHub PAT file (or /dev/null, a no-op)
  - ${SHARED_CREDENTIALS_FILE:-/dev/null}:/home/node/.claude-shared-credentials.json  # Optional: share one login across sessions (or /dev/null, a no-op)
```

**Important note:** The config volume mounts to `/home/node/.claude` (not `/root/.claude`), because the actual Claude Code process runs as the `node` user (UID/GID 1000 by default, non-root — set `PUID`/`PGID` in `.env` if your host user differs). It must be writable by that UID on the host — if `CONFIG_BASE_PATH` is unset it silently falls back to `./configs`, and Docker will auto-create that as root-owned on a brand-new session's first start. If that happens, the entrypoint rejects the unwritable directory at startup (see [Container restart loop](#container-restart-loop) below) instead of crash-looping silently — fix it with a one-time `chown -R <PUID>:<PGID> <CONFIG_BASE_PATH>/<REMOTE_SESSION_NAME>` on the host, or let `./scripts/new-session.sh`/`install.sh` create the directory for you up front with the right ownership.

**On the `GITHUB_TOKEN_FILE`, `GLOBAL_CONFIG_PATH`, and `SHARED_CREDENTIALS_FILE` mounts:** unlike the first two, these are designed to always be present in the `volumes:` list, configured or not — `${VAR:-/dev/null}` is a standard Compose idiom for an "optional file mount": when the corresponding `.env` variable is unset, Compose mounts `/dev/null` instead (reads as empty, harmless). This matters more than it sounds for `GLOBAL_CONFIG_PATH` specifically: an earlier version of this line fell back to a real directory (`./shared-config`, since renamed to `GLOBAL_CONFIG_PATH`) instead, which Docker auto-created (root-owned) on the host even for operators who never touched the `GLOBAL_CONFIG_PATH` feature at all. `entrypoint.sh` only ever does `[ -f ... ]`/`[ -d ... ]` checks against the mounted path, both of which simply evaluate false when the target is `/dev/null` instead of a directory — same silent no-op as not mounting it. If you *do* set `GITHUB_TOKEN_FILE` or `SHARED_CREDENTIALS_FILE` to a host path, make sure the file actually exists there first — Docker auto-creates an empty **directory** at the mount target when the host source is missing, and `entrypoint.sh` detects and warns about that specific case (it can't read a directory as a token, or as shared credentials).

**On `SHARED_CREDENTIALS_FILE` specifically:** by default, every `REMOTE_SESSION_NAME` gets its own isolated credentials — even sessions sharing the same `CONFIG_BASE_PATH` still get separate subfolders (`CONFIG_BASE_PATH/<session>`), so each one prompts for its own login. `SHARED_CREDENTIALS_FILE` is the opt-in way around that: point every session's `.env` at the *same* host file (it must already exist, even empty — `touch` it first), and the first session to log in seeds that file; every session started afterward loads from it instead of prompting. It's mounted to a dedicated path (`/home/node/.claude-shared-credentials.json`), not straight onto the session's own `.credentials.json`, because Compose can't express "mount this file here, but only if the variable is set, otherwise leave whatever's already there alone" — `entrypoint.sh` does the actual copy between the two paths at startup. This is a one-time sync per container start, not a live share: a token that rotates inside an already-running session doesn't propagate to the shared file or to other running containers until they restart.

### Inspect volumes

```bash
# View volumes mounted in the container
docker inspect claude-code-dock | jq '.[0].Mounts'

# List files in the config directory
docker exec claude-code-dock ls -la /home/node/.claude/

# List files in the workspace
docker exec claude-code-dock ls -la /workspace/
```

### Check disk usage

```bash
# Disk usage of volumes
du -sh "${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}"
du -sh "${WORKSPACE_PATH}"
```

---

## Environment Variables

Full reference for every variable claude-code-dock reads, split by where it's
actually consulted. `.env.example` in the repo root carries the same
information grouped by required/optional topic — use that file when writing
your own `.env`; use this table when you need to know source/scope precisely.

### Passed into the container

| Variable | Source | Description |
|----------|--------|-------------|
| `PUID` / `PGID` | `.env` | UID/GID the container remaps its built-in `node` user to before dropping root (default `1000`/`1000`, a no-op when unset). `0` is rejected |
| `CONTAINER_NAME` | `.env` | Informational only inside the container — echoed back in `entrypoint.sh`'s startup banner so the printed `docker exec` command matches this container's real name |
| `AUTO_START_MODE` | `.env` | Execution mode: interactive, remote, shell — validated at startup, invalid values fail fast instead of silently defaulting |
| `CLAUDE_EXTRA_ARGS` | `.env` | Extra arguments for Claude — quote-aware parsing, so quoted substrings with spaces survive as one argument |
| `REMOTE_SESSION_NAME` | `.env` | Session ID — passed into the container; used for the tmux/remote session name and shown in startup logs |
| `TZ` | `.env` | Timezone |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | `.env` | Git commit identity |
| `GITHUB_TOKEN_FILE` | fixed literal | Always `/run/secrets/github_token` inside the container — the host path from `.env`'s `GITHUB_TOKEN_FILE` is only ever used to resolve the volume mount, never passed through directly. See [Git & GitHub Integration](git-integration.md) |
| `GIT_REPO_URL` | `.env` | Repo to auto-clone into `/workspace` on first start |
| `TERM` / `LANG` / `LC_ALL` | `docker-compose.yml` | Terminal type / encoding |

```bash
# Inspect variables inside the container
docker exec claude-code-dock env | sort
```

### Host-only (never passed into the container)

These exist only on the host — either `docker compose` uses them to resolve
the `volumes:`/`image:`/`build:` sections, or a host-side script reads them
directly. `docker exec claude-code-dock env` will never show these.

| Variable | Used by | Description |
|----------|---------|-------------|
| `WORKSPACE_PATH` | `docker-compose.yml` volumes | Host path mounted at `/workspace` |
| `CONFIG_BASE_PATH` | `docker-compose.yml` volumes | Base dir for per-session config, mounted at `/home/node/.claude` |
| `GLOBAL_CONFIG_PATH` | `docker-compose.yml` volumes | Optional global `CLAUDE.md`/`commands/`/`skills/` dir, mounted read-only |
| `SHARED_CREDENTIALS_FILE` | `docker-compose.yml` volumes | Optional host file to share one Claude Code login across sessions instead of one per `REMOTE_SESSION_NAME`. Must already exist as a file (even empty) before first use |
| `CLAUDE_DOCK_TAG` | `docker-compose.yml` `image:` | Published tag to pull (default `latest`; `stable` or a pinned `vX.Y.Z`) |
| `CLAUDE_DOCK_VERSION` | `docker-compose.yml` `build:` | Git ref to build from when the pull fails and `CLAUDE_SOURCE_PATH` is unset (default `main`) |
| `CLAUDE_SOURCE_PATH` | `docker-compose.yml` `build:` | Local clone to build from instead of pulling (advanced/dev) — see [Local development](#local-development) |
| `BACKUP_RETENTION` | `scripts/backup.sh` | Backups kept per session (default `10`) |
| `WATCHDOG_NTFY_URL` | `scripts/watchdog.sh` | Webhook notified on restart/skip — read on the host by the crontab path; see [Watchdog](#watchdog) below |

---

## Logs

There are two different kinds of logs, and they answer different questions.

### Container logs (`docker logs`)

This is the raw stdout/stderr of PID 1. It is useful only during the entrypoint's
startup phase (banner, environment checks, git setup). Once Claude Code starts,
PID 1 becomes tmux running a full-screen TUI, and `docker logs` simply mirrors
whatever is currently drawn on that terminal — not scrolling log lines. This is
also what the Unraid "Logs" button in the Docker UI shows, since it just runs
`docker logs` under the hood: expect it to look empty or garbled (raw ANSI/cursor
codes) once the session is running. That is expected given the [PID 1
architecture](architecture.md), not a bug.

```bash
# Via helper script
./scripts/logs.sh

# Via docker directly
docker logs -f claude-code-dock

# Last 100 lines + follow
docker logs -f --tail 100 claude-code-dock

# Logs from the last hour
docker logs --since 1h claude-code-dock
```

### Startup log (`dock.log`)

The entrypoint also writes a plain-text, timestamped copy of every setup step
(mode, git config, clone result, warnings, errors, the final command executed)
to `${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}/logs/dock.log`. This file is
untouched by tmux/Claude, so it stays readable across restarts and is what you
want for diagnosing startup issues:

```bash
# Via helper script (tails the file directly from the host, no container needed)
./scripts/logs.sh --app

# Or read it directly — it lives in the bind-mounted config volume
tail -f ./configs/<session>/logs/dock.log
```

It is capped at ~2000 lines and trimmed automatically on each container start.

---

## Watchdog

`restart: unless-stopped` in `docker-compose.yml` only reacts to the
container actually **exiting**. Docker never auto-restarts a container that
is still running but reports `unhealthy` (e.g. a wedged tmux pane where
nothing has actually crashed) — that gap needs something to periodically
check `docker inspect`'s health status and act on it.

```bash
./scripts/install.sh --with-watchdog
```

Adds a crontab entry that runs `scripts/watchdog.sh` every 5 minutes,
idempotently (safe to re-run; the entry is only added once). No extra
container, no elevated Docker access — the script runs directly on the host
and talks to the Docker daemon the same way any other host-side `docker`
command does, so it needs no more host privilege than you already have by
being able to run `docker` commands at all.

Running several sessions (`new-session.sh`/`session-up.sh`)? You still only
need this **once** — with no container name given, `watchdog.sh`
auto-discovers every `claude-code-dock*` container on the host and checks
each one, including sessions created after the cron entry was installed. No
per-session cron line to add or remember.

If `crontab` isn't available on this host (some minimal NAS OSes don't
expose one over SSH), `install.sh --with-watchdog` says so and prints the
line to schedule with whatever mechanism the platform does offer.

`WATCHDOG_NTFY_URL` (optional webhook, e.g. an ntfy.sh topic) sends a
notification whenever the watchdog actually restarts the container, fails to
restart it, or skips it because `entrypoint.sh`'s `fatal()` marker shows this
is a persistent misconfiguration rather than a wedged process (see
`scripts/watchdog.sh --help` for the full behavior).

---

## Backups

`scripts/backup.sh` archives `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` (Claude
Code credentials, always included) and `./workspaces/` (if not empty) into a
`.tar.gz` under `./backups/`. It never schedules itself — every run is
either manual or triggered by whatever calls it.

```bash
# One-off, manual
./scripts/backup.sh
```

The archive is always plaintext — pipe it through `gpg` yourself before
moving it anywhere untrusted (see
[Security: Credential Protection](security.md#credential-protection)).

### Automatic daily backups

Set up your own host crontab entry, e.g.:

```bash
(crontab -l 2>/dev/null; echo "0 3 * * * $(pwd)/scripts/backup.sh --quiet") | crontab -
```

This is worth setting up even if you skip the watchdog: losing the config
volume with no backup means re-authenticating Claude Code from scratch and
losing session history, whereas a wedged tmux pane (what the watchdog
guards against) is just an inconvenience.

---

## Resource Limits

`docker-compose.yml` sets no CPU/memory ceiling by default — a hardcoded
value would be wrong for most hosts (a Raspberry Pi and a 32-core Unraid box
have nothing in common).

```bash
docker compose -f docker-compose.yml -f docker-compose.resources.yml up -d
```

`docker-compose.resources.yml` is an opt-in overlay (not auto-loaded by
Compose — explicit `-f` required) that applies a `deploy.resources` block to
the main service. Edit the `cpus`/`memory` values to match your hardware
before using it.

This is a separate file rather than a commented-out block in
`docker-compose.yml` itself for a reason specific to this project:
`docker-compose.override.yml` already exists and is fully managed by
`install.sh`/`update.sh`/`session-up.sh` for `CLAUDE_SOURCE_PATH` (see
[Local development](#local-development) below) — its contents get
regenerated or the file gets deleted outright based on `CLAUDE_SOURCE_PATH`
alone, so anything else placed in it would be silently clobbered on the next
run of those scripts. A separate, explicitly opted-in file avoids that
collision entirely.

---

## Build and Image Update

### Initial setup

By default, `install.sh` (and a plain `docker compose pull`) fetch the
prebuilt, CI-published image from `ghcr.io/leonardomacedocano/claude-code-dock`
instead of building locally — no `apt-get`/`npm install` on your machine:

```bash
# Pull the prebuilt image (default path)
docker compose pull

# Build locally instead (only needed with CLAUDE_SOURCE_PATH set, or if you
# want to test an unreleased change to claude-code-dock itself)
docker compose build
docker compose build --no-cache
```

### Local development

Testing an unreleased change to claude-code-dock itself? Set `CLAUDE_SOURCE_PATH`
in `.env` to your local clone (e.g. `CLAUDE_SOURCE_PATH=.`). This is the
highest-priority source: when set, it always wins over `CLAUDE_DOCK_TAG`
(prebuilt pull) and `CLAUDE_DOCK_VERSION` (GitHub ref) — both are ignored.

`./scripts/install.sh`, `./scripts/update.sh`, and `./scripts/session-up.sh`
detect `CLAUDE_SOURCE_PATH` and generate a `docker-compose.override.yml` next
to `docker-compose.yml` (removing it again if you unset `CLAUDE_SOURCE_PATH`
later). Compose auto-loads that file for *any* invocation run from this
directory — not just these scripts — overriding `image`/`pull_policy` so the
service always builds fresh from `CLAUDE_SOURCE_PATH` into its own dedicated
tag, never silently reusing whatever was already tagged locally (e.g. from an
earlier `docker compose pull`), and never touching GitHub.

This means a bare `docker compose up -d`, or a third-party tool that doesn't
know this project's scripts (e.g. Unraid's Compose Manager plugin), also
gets the correct behavior automatically — as long as it runs from the same
directory as `docker-compose.yml`/`docker-compose.override.yml` (a tool that
copies the compose file elsewhere before running it won't see the override;
in that case, run one of the three scripts above first to generate it, or
force it manually: `docker compose build --no-cache && docker compose up -d`).

To confirm which source is actually running, check the container's startup
log (`./scripts/logs.sh --app`, look for the `Build source:` line) or run
`./scripts/status.sh` — both report `local clone (CLAUDE_SOURCE_PATH=...)` or
`GitHub (ref: ...)` baked into the image at build time, so there's no
ambiguity after the fact.

### Update Claude Code

To update to the latest version of Claude Code:

```bash
# Via script (recommended -- backs up first, pulls by default)
./scripts/update.sh

# Manually
docker compose pull
docker compose up -d
```

The published image is rebuilt on every push to `main`, and on demand via a
manual `workflow_dispatch` run of `docker-publish.yml` (no scheduled/cron
trigger), with a cache-busting build arg specifically for the `npm install -g
@anthropic-ai/claude-code` layer. Run the workflow manually whenever you want
`docker compose pull` to pick up a newer Claude Code release without waiting
on a claude-code-dock commit.

If `CLAUDE_SOURCE_PATH` is set (local development of claude-code-dock itself),
`update.sh` falls back to `docker compose build --no-cache`, which forces a
fresh npm install in that local build too.

### Inspect the built image

```bash
# Claude Code version in the image
docker exec claude-code-dock claude --version

# Which source claude-code-dock itself was built from (local clone or GitHub ref)
docker exec claude-code-dock cat /etc/claude-dock-build-source

# Globally installed npm packages
docker exec claude-code-dock npm list -g --depth=0

# Current container user (should be 'node')
docker exec claude-code-dock whoami

# Image operating system
docker exec claude-code-dock cat /etc/os-release
```

---

## Multiple Instances

The recommended way to run multiple instances is `./scripts/new-session.sh`
(one container + `.env.<name>` per project, sharing a single `CONFIG_BASE_PATH`),
`./scripts/session-up.sh <name>` to start one (it pins `--env-file .env.<name>`
and a matching `-p claude-<name>` Compose project name, so you can't
accidentally start session B under session A's `.env` by forgetting the flag),
and `./scripts/sessions.sh` to list them all — see
[Getting Started: Scripts](getting-started.md#scripts). The manual approach below (one
hand-written compose file with several services) still works if you'd rather
not use the helper scripts:

```yaml
# Modified docker-compose.yml for multiple projects
services:
  claude-project-a:
    build: .
    container_name: claude-project-a
    restart: unless-stopped
    stdin_open: true
    tty: true
    volumes:
      - /mnt/user/project-a:/workspace
      - ./config-project-a:/home/node/.claude

  claude-project-b:
    build: .
    container_name: claude-project-b
    restart: unless-stopped
    stdin_open: true
    tty: true
    volumes:
      - /mnt/user/project-b:/workspace
      - ./config-project-b:/home/node/.claude
```

```bash
# Connect to project A
docker exec -it --user node claude-project-a tmux attach-session -t main

# Connect to project B
docker exec -it --user node claude-project-b tmux attach-session -t main
```

---

## Docker Troubleshooting

### Container does not start

```bash
# View error logs
docker compose logs

# Check status
docker ps -a --filter name=claude-code-dock

# Inspect stopped container
docker inspect claude-code-dock
```

### "Error: cannot attach to a stopped container"

The container stopped unexpectedly. Check logs and restart:

```bash
docker compose logs --tail 50
docker compose up -d
```

### Container restart loop

As of the current entrypoint, this should no longer happen for the most
common causes — the entrypoint validates configuration before doing
anything else and, on a fatal problem, holds the container up (`docker ps`
shows `Up`, not `Restarting`) instead of exiting and letting
`restart: unless-stopped` loop it. Check the last message in the logs first:

```bash
docker logs --tail 30 claude-code-dock
```

You'll see a boxed `✗ FATAL: ...` message naming the exact problem and the
fix, typically one of:
1. `AUTO_START_MODE` set to something other than `interactive`/`remote`/`shell` (a typo)
2. The config or workspace directory is not writable by UID 1000 (`node`) — usually because `CONFIG_BASE_PATH`/`WORKSPACE_PATH` is unset or misspelled, or because Docker auto-created the directory as `root:root` on this session's first start. Fix with a one-time `chown -R <PUID>:<PGID> <path>` on the host (`stat -c '%u:%g' <path>` shows the current owner)

If the container is still actually restarting (not just holding), the crash
is happening somewhere the validation doesn't cover yet — check the full log
and see [Troubleshooting: Container restart loop](troubleshooting.md#container-restart-loop):

```bash
# Test without config volume (clears state)
# Use ghcr.io/leonardomacedocano/claude-code-dock:latest instead if you're on
# the default (pulled, not locally built) image.
docker run --rm -it \
  --user node \
  -v "${WORKSPACE_PATH:-./workspaces}:/workspace" \
  claude-code-dock_claude-code-dock \
  /bin/bash
```

### Disconnect key does not work

If `Ctrl+B, D` does not detach from tmux:

```bash
# Alternative: use tmux command inside the session
# Type: :detach

# Or close the SSH terminal -- Claude keeps running on the server
```

---

## Quick Command Reference

```bash
# Start
docker compose up -d

# Connect
./scripts/attach.sh
# or: docker exec -it --user node claude-code-dock tmux attach-session -t main

# Disconnect (without stopping Claude)
Ctrl+B, D

# Debug shell (separate process)
docker exec -it --user node claude-code-dock bash
# or
./scripts/shell.sh

# Run Claude via exec (separate process)
./scripts/claude.sh

# Run Remote Control via exec
./scripts/remote.sh

# Logs
docker logs -f claude-code-dock
# or
./scripts/logs.sh

# Status
docker ps --filter name=claude-code-dock
# or, for a full summary:
./scripts/status.sh

# Backup (manual; set up your own host crontab entry for a daily schedule)
./scripts/backup.sh

# Apply CPU/memory limits (edit docker-compose.resources.yml first)
docker compose -f docker-compose.yml -f docker-compose.resources.yml up -d

# Stop
docker compose stop

# Restart
docker compose restart

# Update image
./scripts/update.sh
# or manually:
docker compose pull && docker compose up -d

# Remove container (preserves volumes/data)
docker compose down
```
