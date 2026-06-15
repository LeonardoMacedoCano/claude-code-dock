# ClaudeDock

**Claude Code running persistently in Docker — homelab, Unraid, VPS, Linux.**

Persistent login. Persistent workspace. Persistent configuration.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker)](https://www.docker.com/)
[![Unraid](https://img.shields.io/badge/Unraid-Compatible-F15A2C)](https://unraid.net/)

---

## What It Is

ClaudeDock is a Docker infrastructure for running **Claude Code** (`@anthropic-ai/claude-code`) persistently on 24/7 servers — homelab, Unraid, NAS, Proxmox, VPS, or any always-on Linux machine.

You log in **once**. After that, Claude Code is always running with your credentials, your projects, and your configuration — ready to reconnect at any time.

**This project does not modify Claude Code.** It only provides the Docker infrastructure to host it persistently.

**Remote Control is optional.** By default, ClaudeDock runs in interactive mode via `tmux attach-session`. To use Remote Control mode, set `AUTO_START_MODE=remote`.

---

## Problem Solved

| Situation | Before | With ClaudeDock |
|-----------|--------|-----------------|
| Leaving home | Laptop must stay on | Server keeps running |
| Closing terminal | Session ends | Claude keeps running on server |
| Server reboot | Lose configuration | Container restarts already authenticated |
| Switching devices | Start from scratch | Reconnect to existing session |
| Power outage | Lose everything | Restarts automatically |

---

## How It Works

```
Your 24/7 server
+-----------------------------------------------+
|  Docker Container "claude-dock"               |
|  User: node (UID 1000, non-root)              |
|                                               |
|   tmux (PID 1)                                |
|     +-- session "main" --> claude             |
|                                               |
|   /workspace         --> your projects (host) |  <- persistent volume
|   /home/node/.claude --> login + config (host)|  <- persistent volume
+-----------------------------------------------+
              ^
   docker exec -it claude-dock tmux attach-session -t main
              ^
        Any terminal
        (SSH, local, Unraid console, etc.)
```

Claude Code runs inside a tmux session named `main`. tmux is the container's PID 1. To connect, use `./scripts/attach.sh` or `docker exec -it claude-dock tmux attach-session -t main`. When you disconnect with `Ctrl+B D`, Claude keeps running. The next time you connect, the process is the same — nothing was restarted.

---

## Execution Modes

| Mode | Variable | PID 1 | Primary use |
|------|----------|-------|-------------|
| **interactive** (default) | `AUTO_START_MODE=interactive` | `tmux -> claude` | Interactive terminal via `tmux attach-session` |
| **remote** | `AUTO_START_MODE=remote` | `tmux -> claude --remote-control` | Remote Control server for IDEs |
| **shell** | `AUTO_START_MODE=shell` | `bash` | Debug and manual inspection |

---

## Choosing the Right Mode

**Use `interactive` (default) if:**
- You want to use Claude Code directly in the terminal
- You connect to the server via SSH + `./scripts/attach.sh`
- This is your first setup — always start here

**Use `remote` if:**
- You have a Remote Control-compatible client configured
- You want the Remote Control server to run as the main process
- You specifically need `--remote-control`

**Use `shell` if:**
- You are debugging the container
- You want to inspect the environment before starting Claude
- You prefer to start Claude manually when needed

---

## Prerequisites

- Docker Engine 20.10+
- Docker Compose v2+
- 24/7 Linux server (Unraid, NAS, VM, VPS, Raspberry Pi, etc.)

---

## Setup — Docker / Linux

### 1. Clone the project on your server

```bash
git clone https://github.com/LeonardoMacedoCano/ClaudeDock.git ClaudeDock
cd ClaudeDock
```

### 2. Configure `.env`

```bash
cp .env.example .env
nano .env
```

Minimal configuration:

```env
# Where your projects live
WORKSPACE_PATH=/home/user/projects

# Timezone
TZ=America/New_York
```

### 3. Build the image

```bash
docker compose build
```

This downloads the Node.js base image and installs `@anthropic-ai/claude-code`. Takes 3–10 minutes the first time.

### 4. Start the container

```bash
docker compose up -d
```

The container starts in the background. Claude Code is already running inside it, waiting for a connection.

### 5. First login

```bash
./scripts/attach.sh
# or directly:
docker exec -it claude-dock tmux attach-session -t main
```

You will see the Claude Code interface. On the first run, it will ask for authentication — follow the instructions shown by Claude Code.

After completing login, credentials are saved automatically to `./config/` on the host.

### 6. Disconnect without stopping

```
Ctrl+B  then  D
```

> **Important:** `Ctrl+C` sends SIGINT to Claude Code. Always use `Ctrl+B, D` to disconnect (tmux detach).

---

## Setup — Unraid

```bash
# SSH into your Unraid server
ssh root@your-unraid-server

# Navigate to appdata (Unraid convention)
cd /mnt/user/appdata/

# Clone
git clone https://github.com/LeonardoMacedoCano/ClaudeDock.git ClaudeDock
cd ClaudeDock

# Configure
cp .env.example .env
nano .env
```

Recommended configuration for Unraid:

```env
CLAUDE_SOURCE_PATH=/mnt/user/appdata/ClaudeDock
WORKSPACE_PATH=/mnt/cache/projects
CONFIG_PATH=/mnt/user/appdata/ClaudeDock/config
TZ=America/New_York
```

```bash
# Install
chmod +x scripts/install.sh
./scripts/install.sh

# Connect
./scripts/attach.sh
```

If using Unraid, see the [Unraid Guide](docs/unraid.md) for the complete setup including Docker UI configuration.

---

## Setup — Homelab / VPS

```bash
# On any Linux server
git clone https://github.com/LeonardoMacedoCano/ClaudeDock.git
cd ClaudeDock
cp .env.example .env
# Edit WORKSPACE_PATH to point to your projects folder
./scripts/install.sh
```

---

## Persistent Login

Login is done **once** and persists across restarts:

```
First time:
  1. ./scripts/attach.sh
  2. Claude Code displays the authentication flow
  3. You follow the instructions and log in
  4. Credentials saved to ./config/ (on the host, outside the container)

After a restart:
  1. Container restarts automatically (restart: unless-stopped)
  2. Claude Code reads credentials from ./config/ -> already authenticated
  3. ./scripts/attach.sh -> ready to use
```

**Why it works:** The `~/.claude/` directory inside the container is a bind mount volume pointing to `./config/` on the host. Credentials live on the server's disk and persist across container restarts.

---

## Persistent Workspace

The `/workspace` directory inside the container points to `WORKSPACE_PATH` on the host.

Your projects live on the server, accessible from inside the container. Even if the container is deleted and recreated, your files remain intact on the host.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WORKSPACE_PATH` | `./workspaces` | Path to projects on the host |
| `CONFIG_PATH` | `./config` | Path to credentials on the host |
| `AUTO_START_MODE` | `interactive` | Mode: `interactive`, `remote`, `shell` |
| `CLAUDE_AUTO_APPROVE` | `true` | Enables `--dangerously-skip-permissions` |
| `REMOTE_SESSION_NAME` | `` | Session name for remote mode (leave empty for hostname) |
| `CLAUDE_EXTRA_ARGS` | `` | Extra arguments for Claude |
| `TZ` | `UTC` | Timezone |
| `GIT_USER_NAME` | `` | Name for git commits |
| `GIT_USER_EMAIL` | `` | Email for git commits |

### CLAUDE_AUTO_APPROVE

```env
CLAUDE_AUTO_APPROVE=true   # Claude executes without asking for confirmation (recommended for personal server)
CLAUDE_AUTO_APPROVE=false  # Claude asks for approval before each action
```

Enables the `--dangerously-skip-permissions` flag in Claude Code, which disables confirmation prompts before running commands, creating, or editing files.

### CLAUDE_EXTRA_ARGS

Appends extra arguments to the final command:

```env
CLAUDE_EXTRA_ARGS=--model sonnet
CLAUDE_EXTRA_ARGS=--verbose
CLAUDE_EXTRA_ARGS=--debug
```

---

## Daily Use

```bash
# Connect to Claude Code on the server
./scripts/attach.sh
# or directly:
docker exec -it claude-dock tmux attach-session -t main

# ... use Claude normally ...

# Disconnect without stopping (tmux detach)
Ctrl+B, D
```

### What happens in each situation

**You close the terminal / SSH drops:**
The container keeps running. On the next connection, Claude is exactly where you left it.

**The server reboots:**
With `restart: unless-stopped`, Docker restarts the container automatically. Claude Code starts already authenticated. Just reconnect.

**Claude Code crashes or you type `/exit`:**
The container stops and restarts automatically (restart policy). Just reconnect after a few seconds.

---

## Available Scripts

```bash
./scripts/install.sh      # Full initial setup
./scripts/update.sh       # Update Claude Code (rebuild + restart)
./scripts/attach.sh       # Connect to Claude Code (tmux session)
./scripts/shell.sh        # Open bash in the container (separate process)
./scripts/logs.sh         # View container logs in real time
./scripts/backup.sh       # Backup credentials
./scripts/restore.sh      # Restore a backup
./scripts/claude.sh       # Run Claude in the container via docker exec
./scripts/remote.sh       # Run Claude Remote Control via docker exec
```

---

## Updating Claude Code

```bash
./scripts/update.sh
```

The script backs up credentials, rebuilds the image with `--no-cache` (installs the latest version of `@anthropic-ai/claude-code`), and restarts the container. **Login is preserved.**

---

## Backup

```bash
# Create backup
./scripts/backup.sh

# List available backups
./scripts/restore.sh --list

# Restore a specific backup
./scripts/restore.sh ./backups/claude-dock-backup-2024-01-15_14-30-00.tar.gz
```

---

## Project Structure

```
ClaudeDock/
+-- Dockerfile              <- Image with Claude Code installed (node user, non-root)
+-- docker-compose.yml      <- Container orchestration
+-- .env.example            <- Configuration template
+-- docker/
|   +-- entrypoint.sh       <- Container initialization and mode control
+-- scripts/
|   +-- install.sh          <- Initial setup
|   +-- update.sh           <- Update
|   +-- attach.sh           <- Connect to Claude Code (tmux attach)
|   +-- backup.sh           <- Credential backup
|   +-- restore.sh          <- Restore backup
|   +-- shell.sh            <- Shell in container (separate process)
|   +-- logs.sh             <- Real-time logs
|   +-- claude.sh           <- Run Claude via docker exec
|   +-- remote.sh           <- Run Remote Control via docker exec
+-- docs/
|   +-- architecture.md     <- Architecture and design decisions
|   +-- docker.md           <- Docker commands reference
|   +-- unraid.md           <- Complete Unraid guide
|   +-- troubleshooting.md  <- Problem resolution
|   +-- security.md         <- Security and best practices
+-- config/                 <- Claude Code credentials (do not commit -- in .gitignore)
+-- workspaces/             <- Default local workspace (fallback)
```

---

## Persistence

| What | Inside container | On host | Persists? |
|------|-----------------|---------|-----------|
| Credentials / login | `/home/node/.claude/` | `CONFIG_PATH` (default: `./config`) | Yes |
| Projects / code | `/workspace/` | `WORKSPACE_PATH` | Yes |

Both are bind mount volumes — data lives on the host, not in the container. Deleting and recreating the container does not lose data.

---

## WORKSPACE_PATH Examples by Platform

```env
# Standard Linux
WORKSPACE_PATH=/home/user/projects

# Unraid -- cache SSD (recommended, faster)
WORKSPACE_PATH=/mnt/cache/projects

# Unraid -- HDD array
WORKSPACE_PATH=/mnt/user/projects

# Synology NAS
WORKSPACE_PATH=/volume1/projects

# QNAP
WORKSPACE_PATH=/share/projects

# Proxmox Linux VM
WORKSPACE_PATH=/opt/projects

# Raspberry Pi
WORKSPACE_PATH=/home/pi/projects

# Local test (no external server)
WORKSPACE_PATH=./workspaces
```

---

## Security

- **No exposed ports** — interaction exclusively via terminal
- **Non-root user** — container runs as `node` (UID 1000)
- **Isolated credentials** — `./config/` excluded from git via `.gitignore`
- **External access** — use SSH + VPN (Tailscale, WireGuard) instead of exposing the server

For security guidance, see [Security](docs/security.md).

---

## Compatibility

| Platform | Status |
|----------|--------|
| Linux x86_64 | Supported |
| Linux ARM64 (Raspberry Pi 4/5) | Supported |
| Unraid 6.10+ | Supported -- see [Unraid Guide](docs/unraid.md) |
| Synology DSM | Supported |
| QNAP QTS | Supported |
| TrueNAS Scale | Supported |
| Proxmox (Linux VM) | Supported |

---

## Documentation

| Document | Description |
|----------|-------------|
| [Unraid Guide](docs/unraid.md) | Complete setup for Unraid, Docker UI configuration, Unraid Console |
| [Docker Reference](docs/docker.md) | Docker commands, volumes, logs, troubleshooting |
| [Architecture](docs/architecture.md) | tmux/PID 1 design, data flow, design decisions |
| [Troubleshooting Guide](docs/troubleshooting.md) | Common problems and solutions |
| [Security](docs/security.md) | Credential protection, remote access, security checklist |

---

## FAQ

**Do I need to log in every time the container restarts?**

No. Login is done once. Credentials are saved in `./config/` on the host and loaded automatically on every restart.

---

**What is `--dangerously-skip-permissions`?**

An official Claude Code flag that disables confirmation prompts before running commands, creating, or editing files. With `CLAUDE_AUTO_APPROVE=true` in `.env`, the container uses this flag by default. Recommended for personal servers where you are the only user.

---

**Why does the container run as a non-root user?**

Claude Code 2.x blocks `--dangerously-skip-permissions` when run as root (UID 0). ClaudeDock uses the `node` user (UID 1000) to work around this restriction and as a security best practice.

---

**How do I access from outside my home network?**

Via SSH to the server + `./scripts/attach.sh`. Use Tailscale or WireGuard for secure access without exposing the server to the internet.

---

**How do I open a shell in the container without affecting Claude?**

```bash
./scripts/shell.sh
# or directly:
docker exec -it claude-dock bash
```

This opens a **separate** bash process without interfering with the Claude Code session.

---

**What happens if the server reboots?**

The container starts automatically (`restart: unless-stopped`), Claude Code launches already authenticated. Just run `./scripts/attach.sh` to reconnect.

---

**How do I use Remote Control mode?**

Set `AUTO_START_MODE=remote` in `.env` and restart the container:
```bash
nano .env  # AUTO_START_MODE=remote
docker compose up -d --force-recreate
```

Or use `./scripts/remote.sh` for a temporary Remote Control session without changing the main mode.

---

## Quick Troubleshooting

| Problem | Solution |
|---------|----------|
| Container does not start | `docker compose logs` to see the error |
| Asks for login every time | Check if `./config/` has files and is mounted correctly |
| Cannot connect via `attach.sh` | Verify container is running: `docker ps` |
| Garbled interface | Check `TERM=xterm-256color` in `.env` and recreate container |
| Empty workspace | Check `WORKSPACE_PATH` in `.env` and that the folder exists on host |
| Permission denied on workspace | `chown -R 1000:1000 /your/workspace/` (UID 1000 = node user) |

For detailed troubleshooting, see [Troubleshooting Guide](docs/troubleshooting.md).

---

## Legal Notice

ClaudeDock is an independent open source project, not affiliated with Anthropic. Claude Code is a product of Anthropic. All use is subject to the [Anthropic Usage Policy](https://www.anthropic.com/legal/aup).

## License

MIT License
