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

The project uses four volumes:

```yaml
volumes:
  - ${WORKSPACE_PATH}:/workspace                                     # User projects
  - ${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}:/home/node/.claude     # Claude Code credentials (per-session)
  - ${SHARED_CONFIG_PATH}:/home/node/.claude-shared:ro                # Optional: global CLAUDE.md/commands
  - ${GITHUB_TOKEN_FILE:-/dev/null}:/run/secrets/github_token:ro      # Optional: GitHub PAT file (or /dev/null, a no-op)
```

**Important note:** The config volume mounts to `/home/node/.claude` (not `/root/.claude`), because the actual Claude Code process runs as the `node` user (UID/GID 1000 by default, non-root — set `PUID`/`PGID` in `.env` if your host user differs). It must be writable by that UID on the host — if `CONFIG_BASE_PATH` is unset it silently falls back to `./configs`, and Docker will auto-create that as root-owned, which the entrypoint now rejects at startup (see [Container restart loop](#container-restart-loop) below) instead of crash-looping silently.

**On the `GITHUB_TOKEN_FILE` mount:** unlike the other three, this one is designed to always be present in the `volumes:` list, token configured or not — `${GITHUB_TOKEN_FILE:-/dev/null}` is a standard Compose idiom for an "optional file mount": when `.env`'s `GITHUB_TOKEN_FILE` is unset, Compose mounts `/dev/null` instead (reads as empty, harmless). If you *do* set `GITHUB_TOKEN_FILE` to a host path, make sure the file actually exists there first — Docker auto-creates an empty **directory** at the mount target when the host source is missing, and `entrypoint.sh` detects and warns about that specific case (it can't read a directory as a token).

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

### Available variables in the container

| Variable | Source | Description |
|----------|--------|-------------|
| `AUTO_START_MODE` | `.env` | Execution mode: interactive, remote, shell — validated at startup, invalid values now fail fast instead of silently defaulting |
| `CLAUDE_AUTO_APPROVE` | `.env` | Enables --dangerously-skip-permissions (default `false`) |
| `CLAUDE_EXTRA_ARGS` | `.env` | Extra arguments for Claude — quote-aware parsing, so quoted substrings with spaces survive as one argument |
| `REMOTE_SESSION_NAME` | `.env` | Session ID — passed into the container; used for the tmux/remote session name and shown in startup logs |
| `TZ` | `.env` | Timezone |
| `GIT_USER_NAME` | `.env` | Name for git commits |
| `GIT_USER_EMAIL` | `.env` | Email for git commits |
| `GITHUB_TOKEN_FILE` | `.env` | HOST path to a file with the GitHub PAT — auto-mounted read-only to the fixed in-container path `/run/secrets/github_token` via the `${GITHUB_TOKEN_FILE:-/dev/null}` volume idiom in `docker-compose.yml` |
| `GIT_REPO_URL` | `.env` | Repo to auto-clone into `/workspace` on first start |
| `TERM` | `docker-compose.yml` | Terminal type |
| `LANG` | `docker-compose.yml` | Default encoding |

`WORKSPACE_PATH`, `CONFIG_BASE_PATH`, and `SHARED_CONFIG_PATH` are **not** passed into the container as environment variables — they only exist on the host, where `docker compose` uses them to resolve the `volumes:` section. Inside the container you only ever see the mounted paths (`/workspace`, `/home/node/.claude`, `/home/node/.claude-shared`).

### Inspect variables inside the container

```bash
docker exec claude-code-dock env | sort
```

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

`./scripts/install.sh` and `./scripts/update.sh` detect `CLAUDE_SOURCE_PATH`
and automatically switch to `docker compose build --no-cache`, so your local
folder is guaranteed to be what actually gets built — never a stale image
already tagged locally, and never GitHub.

If you run `docker compose` commands directly instead of the scripts, you
must force that same guarantee yourself. `docker-compose.yml` declares both
`image:` and `build:` on the service (needed so `docker compose pull` still
works for everyone else) — which means Compose only builds when the image tag
doesn't already exist locally. A bare `docker compose up -d` will silently
reuse whatever is already tagged there (e.g. from an earlier `docker compose
pull`) and ignore your `CLAUDE_SOURCE_PATH` changes entirely:

```bash
# Correct — forces a fresh build from CLAUDE_SOURCE_PATH every time:
docker compose build --no-cache && docker compose up -d
# or the equivalent one-liner:
docker compose up -d --build

# Wrong when testing local changes — reuses whatever image is already
# tagged locally instead of rebuilding, if one exists:
docker compose up -d
```

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

The published image is rebuilt weekly (and on every push to `main`) with a
cache-busting build arg specifically for the `npm install -g
@anthropic-ai/claude-code` layer, so `docker compose pull` reliably gets a
recent Claude Code release without waiting on a claude-code-dock commit.

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
[README: Scripts](../README.md#scripts). The manual approach below (one
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
2. The config or workspace directory is not writable by UID 1000 (`node`) — usually because `CONFIG_BASE_PATH`/`WORKSPACE_PATH` is unset, misspelled, or the host directory is still owned by root

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
