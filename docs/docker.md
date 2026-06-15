# Docker Reference — ClaudeDock

For Docker commands reference, see this document. For architecture details, see [Architecture](architecture.md). For troubleshooting, see [Troubleshooting Guide](troubleshooting.md).

## Core Concepts

Before using ClaudeDock, it helps to understand how Docker containers behave in this project.

### Container as a "Persistent Server"

In many projects, containers are ephemeral — created, used, and discarded. In ClaudeDock, the container is treated as a persistent server, similar to a system service:

```
Conventional server:       ClaudeDock:
+------------------+       +------------------------------+
|  systemd service |       |  Docker container            |
|  nginx (PID 1)   |  ~=   |  tmux (PID 1)                |
|  Auto restart    |       |  restart: unless-stopped     |
|  Persistent logs |       |  Persistent volumes          |
+------------------+       +------------------------------+
```

### How tmux fits in

Claude Code runs inside a tmux session named `main`. tmux is the container's PID 1. This means:

- `docker exec -it claude-dock tmux attach-session -t main` connects to the running Claude session
- `Ctrl+B D` detaches from the session without killing Claude
- `docker exec -it claude-dock bash` opens a separate shell for inspection, without touching Claude

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
docker exec -it claude-dock tmux attach-session -t main

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

### ClaudeDock volumes

The project uses two main volumes:

```yaml
volumes:
  - ${WORKSPACE_PATH}:/workspace          # User projects
  - ${CONFIG_PATH}:/home/node/.claude     # Claude Code credentials
```

**Important note:** The config volume mounts to `/home/node/.claude` (not `/root/.claude`), because the container runs as the `node` user (UID 1000, non-root).

### Inspect volumes

```bash
# View volumes mounted in the container
docker inspect claude-dock | jq '.[0].Mounts'

# List files in the config directory
docker exec claude-dock ls -la /home/node/.claude/

# List files in the workspace
docker exec claude-dock ls -la /workspace/
```

### Check disk usage

```bash
# Disk usage of volumes
du -sh ./config/
du -sh "${WORKSPACE_PATH}"
```

---

## Environment Variables

### Available variables in the container

| Variable | Source | Description |
|----------|--------|-------------|
| `AUTO_START_MODE` | `.env` | Execution mode: interactive, remote, shell |
| `CLAUDE_AUTO_APPROVE` | `.env` | Enables --dangerously-skip-permissions |
| `CLAUDE_EXTRA_ARGS` | `.env` | Extra arguments for Claude |
| `WORKSPACE_PATH` | `.env` | Workspace path on host |
| `TZ` | `.env` | Timezone |
| `GIT_USER_NAME` | `.env` | Name for git commits |
| `GIT_USER_EMAIL` | `.env` | Email for git commits |
| `TERM` | `docker-compose.yml` | Terminal type |
| `LANG` | `docker-compose.yml` | Default encoding |

### Inspect variables inside the container

```bash
docker exec claude-dock env | sort
```

---

## Logs

### View logs in real time

```bash
# Via helper script
./scripts/logs.sh

# Via docker directly
docker logs -f claude-dock

# Last 100 lines + follow
docker logs -f --tail 100 claude-dock

# Logs from the last hour
docker logs --since 1h claude-dock
```

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
docker exec claude-dock claude --version

# Globally installed npm packages
docker exec claude-dock npm list -g --depth=0

# Current container user (should be 'node')
docker exec claude-dock whoami

# Image operating system
docker exec claude-dock cat /etc/os-release
```

---

## Multiple Instances

It is possible to run multiple instances for different projects:

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
docker ps -a --filter name=claude-dock

# Inspect stopped container
docker inspect claude-dock
```

### "Error: cannot attach to a stopped container"

The container stopped unexpectedly. Check logs and restart:

```bash
docker compose logs --tail 50
docker compose up -d
```

### Container restart loop

Indicates the main process is crashing at startup. Common causes:
1. Permission issue on the `./config` volume
2. Corrupted configuration file
3. Incompatible Node.js version

```bash
# Check crash logs
docker compose logs --tail 20

# Test without config volume (clears state)
docker run --rm -it \
  --user node \
  -v "${WORKSPACE_PATH:-./workspaces}:/workspace" \
  claude-dock_claude-dock \
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
# or: docker exec -it claude-dock tmux attach-session -t main

# Disconnect (without stopping Claude)
Ctrl+B, D

# Debug shell (separate process)
docker exec -it claude-dock bash
# or
./scripts/shell.sh

# Run Claude via exec (separate process)
./scripts/claude.sh

# Run Remote Control via exec
./scripts/remote.sh

# Logs
docker logs -f claude-dock
# or
./scripts/logs.sh

# Status
docker ps --filter name=claude-dock

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
