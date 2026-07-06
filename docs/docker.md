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

- `docker exec -it claude-code-dock tmux attach-session -t main` connects to the running Claude session
- `Ctrl+B D` detaches from the session without killing Claude
- `docker exec -it claude-code-dock bash` opens a separate shell for inspection, without touching Claude

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
docker exec -it claude-code-dock tmux attach-session -t main

# To disconnect WITHOUT stopping Claude:
# Press Ctrl+B then D
```

**Why `tmux attach-session` and not `docker attach`?**

Claude Code runs inside a tmux session named `main`. The container's PID 1 is `tmux`. `docker exec -it ... tmux attach-session -t main` connects to the existing session where Claude is running.

`docker exec -it ... bash` opens a new separate shell, useful for inspection but not for using Claude directly.

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

The project uses three volumes:

```yaml
volumes:
  - ${WORKSPACE_PATH}:/workspace                                     # User projects
  - ${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}:/home/node/.claude     # Claude Code credentials (per-session)
  - ${SHARED_CONFIG_PATH}:/home/node/.claude-shared:ro                # Optional: global CLAUDE.md/commands
```

**Important note:** The config volume mounts to `/home/node/.claude` (not `/root/.claude`), because the container runs as the `node` user (UID 1000, non-root). It must be writable by UID 1000 on the host — if `CONFIG_BASE_PATH` is unset it silently falls back to `./configs`, and Docker will auto-create that as root-owned, which the entrypoint now rejects at startup (see [Container restart loop](#container-restart-loop) below) instead of crash-looping silently.

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
| `CLAUDE_AUTO_APPROVE` | `.env` | Enables --dangerously-skip-permissions |
| `CLAUDE_EXTRA_ARGS` | `.env` | Extra arguments for Claude |
| `REMOTE_SESSION_NAME` | `.env` | Session ID — passed into the container; used for the tmux/remote session name and shown in startup logs |
| `TZ` | `.env` | Timezone |
| `GIT_USER_NAME` | `.env` | Name for git commits |
| `GIT_USER_EMAIL` | `.env` | Email for git commits |
| `GITHUB_TOKEN` | `.env` | GitHub PAT for push/pull authentication |
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

### Initial build

```bash
# Build the local image
docker compose build

# Build without cache (forces Claude Code reinstall)
docker compose build --no-cache
```

### Update Claude Code

To update to the latest version of Claude Code:

```bash
# Via script (recommended -- backs up first)
./scripts/update.sh

# Manually
docker compose build --no-cache
docker compose up -d
```

The `--no-cache` flag ensures npm downloads and installs the latest version of `@anthropic-ai/claude-code`.

### Inspect the built image

```bash
# Claude Code version in the image
docker exec claude-code-dock claude --version

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
(one container + `.env.<name>` per project, sharing a single `CONFIG_BASE_PATH`)
and `./scripts/sessions.sh` to list them — see [README: Scripts](../README.md#scripts).
The manual approach below (one hand-written compose file with several
services) still works if you'd rather not use the helper scripts:

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
docker exec -it claude-project-a tmux attach-session -t main

# Connect to project B
docker exec -it claude-project-b tmux attach-session -t main
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
# or: docker exec -it claude-code-dock tmux attach-session -t main

# Disconnect (without stopping Claude)
Ctrl+B, D

# Debug shell (separate process)
docker exec -it claude-code-dock bash
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
docker compose build --no-cache && docker compose up -d

# Remove container (preserves volumes/data)
docker compose down
```
