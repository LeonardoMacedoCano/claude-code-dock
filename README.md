# ClaudeCodeDock

**Have Claude Code always running — one container per project, Remote Control ready, zero friction.**

> You open Claude on your phone, tablet, or any device. Your projects are already there, running on your server, 24/7. You just connect and ask Claude to do the work.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker)](https://www.docker.com/)
[![Unraid](https://img.shields.io/badge/Unraid-Compatible-F15A2C)](https://unraid.net/)

---

## Is This What You Need?

**ClaudeCodeDock is for you if:**
- You want to use [Claude Remote Control](https://docs.anthropic.com/en/docs/claude-code/remote-development) from any device — without having to prepare anything in advance
- You have a server (homelab, Unraid, NAS, VPS, Raspberry Pi) that stays on 24/7
- You want multiple projects always available — each with its own Claude session
- You're tired of Remote Control freezing and not being able to unblock it remotely

**ClaudeCodeDock is not for you if:**
- You don't have a 24/7 server
- You only want to use Claude Code interactively on your main machine (just install `@anthropic-ai/claude-code` directly)

---

## The Problem It Solves

Claude Remote Control is powerful — you can control Claude from the Claude.ai interface, from your phone, from any device. But it has two friction points:

**Problem 1 — You have to prepare in advance.**
To use Remote Control, your machine needs to have Claude running with `--remote-control` before you connect. If you close the terminal, leave home, or your machine sleeps — the session is gone. You can't connect to something that isn't running.

**Problem 2 — Remote Control can freeze.**
It happens: Claude asks for permission to run a command, you approve from the remote interface, but it stays stuck. The only fix is physical access to the terminal where Claude is running. If you're away from home, you're stuck.

**What ClaudeCodeDock does:**
- Runs Claude inside Docker on your 24/7 server — it's always on, always ready
- Each container = one project, with its own workspace and its own session name
- Remote Control is enabled by default — just open Claude.ai and your sessions are there
- If a session freezes, connect to your server via VPN and unblock it from the tmux terminal
- One login for all containers — credentials shared via a single config folder

---

## The Multi-Project Pattern

This is the core idea: **one ClaudeCodeDock container per project**, all running on the same server, all sharing the same login.

```
Your 24/7 server
+------------------------------------------------------------------+
|                                                                  |
|  Container: claudecodedock-homepage                              |
|  REMOTE_SESSION_NAME=HomePage                                    |
|  WORKSPACE_PATH=/srv/homepage                                    |
|  CONFIG_PATH=/srv/claude-config  <-- shared login                |
|                                                                  |
|  Container: claudecodedock-calendar                              |
|  REMOTE_SESSION_NAME=Calendar                                    |
|  WORKSPACE_PATH=/home/user/calendar-assistant                    |
|  CONFIG_PATH=/srv/claude-config  <-- same folder                 |
|                                                                  |
|  Container: claudecodedock-investments                           |
|  REMOTE_SESSION_NAME=Investments                                 |
|  WORKSPACE_PATH=/home/user/investment-portfolio                  |
|  CONFIG_PATH=/srv/claude-config  <-- same folder                 |
|                                                                  |
+------------------------------------------------------------------+
                          |
          Open Claude.ai Remote Control
                          |
          +---------------+---------------+
          |               |               |
       HomePage        Calendar      Investments
   (always there)   (always there)  (always there)
```

From Claude.ai Remote Control, you see all three sessions by name. Click one, start working. Done.

---

## Real Use Cases

### Homepage in production

You have a website running on your server, configured with a domain. Create a ClaudeCodeDock container pointing the workspace to your site's production folder:

```env
REMOTE_SESSION_NAME=HomePage
WORKSPACE_PATH=/srv/www/myhomepage.com
AUTO_START_MODE=remote
```

Now from anywhere you can ask: *"Update the About page with my new contact info"* — Claude is running directly on the server, in the production folder, with your files.

---

### Calendar assistant

A folder with your calendar data, scripts, and notes. Claude always running with full context:

```env
REMOTE_SESSION_NAME=Calendar
WORKSPACE_PATH=/home/user/calendar-assistant
AUTO_START_MODE=remote
```

Ask: *"What do I have this week that conflicts with my trip?"* or *"Create an event template for my weekly meetings"*.

---

### Personal investment assistant

A private folder containing your portfolio spreadsheets, notes on assets, investment history. Claude with full context on your financial situation:

```env
REMOTE_SESSION_NAME=Investments
WORKSPACE_PATH=/home/user/investment-portfolio
AUTO_START_MODE=remote
```

Ask: *"Based on my current portfolio, where does it make sense to invest this month?"* — Claude reads your files, knows your history, and helps you decide.

---

### The limit is your imagination

One 24/7 server. Any number of ClaudeCodeDock containers. Each with:
- Its own project folder
- Its own session name (visible in Remote Control)
- Its own dedicated Claude instance

A recipe assistant. A home automation helper. A private journal with AI analysis. A documentation project. A study environment. Each one is always on, always accessible, ready the moment you open Claude.ai.

---

## Setup: One-Time Global Configuration

Before creating any container, set up two folders that all containers will share. **You only do this once.**

### Step 1 — Clone ClaudeCodeDock to your server

```bash
# Choose a permanent location on your server
git clone https://github.com/LeonardoMacedoCano/ClaudeCodeDock.git /srv/claudecodedock
```

This folder will be referenced by all containers as `CLAUDE_SOURCE_PATH`. You never need to clone it again.

### Step 2 — Create the shared config folder

```bash
mkdir -p /srv/claude-config
```

This is `CONFIG_PATH`. It stores your Claude login credentials. **All containers share this folder** — so you only log in once, with the very first container you create.

---

## Creating Your First Container

### 1. Copy the compose file

```bash
mkdir -p /srv/projects/homepage
cp /srv/claudecodedock/.env.example /srv/projects/homepage/.env
cp /srv/claudecodedock/docker-compose.yml /srv/projects/homepage/docker-compose.yml
```

### 2. Configure `.env`

```env
# The ClaudeCodeDock source (points to where you cloned it)
CLAUDE_SOURCE_PATH=/srv/claudecodedock

# Shared login credentials — configure once, reuse everywhere
CONFIG_PATH=/srv/claude-config

# This project's folder
WORKSPACE_PATH=/srv/www/myhomepage.com

# Session name as it will appear in Claude Remote Control
REMOTE_SESSION_NAME=HomePage

# Enable Remote Control mode
AUTO_START_MODE=remote

# Container name — must be unique per container
# Edit docker-compose.yml: container_name: claudecodedock-homepage

TZ=America/Sao_Paulo
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@email.com
```

### 3. Build and start

```bash
cd /srv/projects/homepage
docker compose build
docker compose up -d
```

### 4. First login (only once, for the first container)

```bash
docker exec -it claudecodedock-homepage tmux attach-session -t main
```

Claude Code will display the authentication flow. Complete it. Credentials are saved to `/srv/claude-config/`.

Disconnect with `Ctrl+B, D`. The container keeps running.

### 5. Open Claude.ai Remote Control

Your `HomePage` session is there, connected to your server's production folder.

---

## Creating Additional Containers

For the second, third, tenth container — **no login required.** Just copy, configure, and start:

```bash
mkdir -p /srv/projects/calendar
cp /srv/claudecodedock/.env.example /srv/projects/calendar/.env
cp /srv/claudecodedock/docker-compose.yml /srv/projects/calendar/docker-compose.yml
```

Edit `/srv/projects/calendar/.env`:

```env
CLAUDE_SOURCE_PATH=/srv/claudecodedock
CONFIG_PATH=/srv/claude-config        # <-- same folder, already authenticated
WORKSPACE_PATH=/home/user/calendar-assistant
REMOTE_SESSION_NAME=Calendar
AUTO_START_MODE=remote
TZ=America/Sao_Paulo
```

Edit `docker-compose.yml` to set a unique container name:
```yaml
container_name: claudecodedock-calendar
```

Then:
```bash
cd /srv/projects/calendar
docker compose build
docker compose up -d
```

Done. `Calendar` appears in Claude Remote Control, already authenticated.

---

## If a Session Freezes

It happens with Remote Control — a permission prompt gets stuck. The fix:

1. Connect to your server via VPN (Tailscale, WireGuard, etc.)
2. SSH into the server
3. Attach to the frozen container's tmux session:
   ```bash
   docker exec -it claudecodedock-homepage tmux attach-session -t main
   ```
4. Respond to the prompt or unblock whatever is stuck
5. Disconnect with `Ctrl+B, D`

The session resumes normally in Remote Control. This is exactly why ClaudeCodeDock runs Claude inside tmux — you can always reach the terminal, from anywhere, via VPN.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_SOURCE_PATH` | `.` | Path to the ClaudeCodeDock clone on the host |
| `CONFIG_PATH` | `./config` | Path to credentials — share this across all containers |
| `WORKSPACE_PATH` | `./workspaces` | This container's project folder |
| `AUTO_START_MODE` | `interactive` | Mode: `interactive`, `remote`, `shell` |
| `CLAUDE_AUTO_APPROVE` | `true` | Enables `--dangerously-skip-permissions` |
| `REMOTE_SESSION_NAME` | `` | Session name visible in Remote Control |
| `CLAUDE_EXTRA_ARGS` | `` | Extra arguments passed to Claude |
| `TZ` | `UTC` | Timezone |
| `GIT_USER_NAME` | `` | Name for git commits |
| `GIT_USER_EMAIL` | `` | Email for git commits |

### Key variables explained

**`CONFIG_PATH`** — Points to the folder where Claude stores credentials. Set it to the same path in every container and you only log in once.

**`REMOTE_SESSION_NAME`** — The name that appears in Claude.ai Remote Control when you connect. Make it descriptive: `HomePage`, `Calendar`, `Investments`, `RecipeBot`, etc.

**`AUTO_START_MODE=remote`** — Starts Claude with `--remote-control` as the main process. This is the recommended mode for always-on containers.

**`CLAUDE_AUTO_APPROVE=true`** — Enables `--dangerously-skip-permissions`, so Claude doesn't ask for confirmation before running commands. Recommended for personal servers.

---

## Execution Modes

| Mode | Variable | Use when |
|------|----------|----------|
| **remote** | `AUTO_START_MODE=remote` | Main use case — Claude Remote Control from any device |
| **interactive** | `AUTO_START_MODE=interactive` | You want to use Claude directly in the terminal via SSH |
| **shell** | `AUTO_START_MODE=shell` | Debugging the container |

---

## Available Scripts

From inside any ClaudeCodeDock project folder:

```bash
./scripts/install.sh      # Full initial setup
./scripts/update.sh       # Update Claude Code (rebuild + restart)
./scripts/attach.sh       # Connect to the tmux session (for debugging or unblocking)
./scripts/shell.sh        # Open bash in the container (separate process)
./scripts/logs.sh         # View container logs in real time
./scripts/backup.sh       # Backup credentials
./scripts/restore.sh      # Restore a backup
./scripts/claude.sh       # Run Claude via docker exec
./scripts/remote.sh       # Run Remote Control via docker exec (temporary session)
```

---

## How It Works Internally

```
Your 24/7 server
+-----------------------------------------------+
|  Docker Container "claudecodedock-homepage"        |
|  User: node (UID 1000, non-root)              |
|                                               |
|   tmux (PID 1)                                |
|     +-- session "main" --> claude --remote-control
|                                               |
|   /workspace         --> WORKSPACE_PATH (host)|
|   /home/node/.claude --> CONFIG_PATH (host)   |
+-----------------------------------------------+
              ^
   Remote Control from Claude.ai (any device)
   or:
   docker exec -it claudecodedock-homepage tmux attach-session -t main
   (for debugging / unblocking)
```

Claude runs inside a tmux session. tmux is PID 1 of the container. If you detach (`Ctrl+B, D`) or Remote Control disconnects, Claude keeps running — the tmux session stays alive, the container stays alive, your work continues.

---

## Persistent Login

```
First container, first time:
  1. docker exec -it claudecodedock-<name> tmux attach-session -t main
  2. Claude Code shows authentication flow
  3. You log in
  4. Credentials saved to CONFIG_PATH on the host

Every other container, every restart:
  - Container mounts CONFIG_PATH -> /home/node/.claude/
  - Claude reads credentials -> already authenticated
  - No login needed
```

---

## Project Structure

```
ClaudeCodeDock/
+-- Dockerfile              <- Image with Claude Code (node user, non-root)
+-- docker-compose.yml      <- Container orchestration template
+-- .env.example            <- Configuration template
+-- docker/
|   +-- entrypoint.sh       <- Initialization and mode control
+-- scripts/
|   +-- install.sh
|   +-- update.sh
|   +-- attach.sh
|   +-- backup.sh
|   +-- restore.sh
|   +-- shell.sh
|   +-- logs.sh
|   +-- claude.sh
|   +-- remote.sh
+-- docs/
|   +-- architecture.md
|   +-- docker.md
|   +-- unraid.md
|   +-- troubleshooting.md
|   +-- security.md
+-- config/                 <- Local credentials (not committed -- in .gitignore)
+-- workspaces/             <- Default local workspace (fallback)
```

---

## Security

- **No exposed ports** — interaction via tmux terminal or Claude Remote Control (which uses Claude's own secure channel)
- **Non-root user** — container runs as `node` (UID 1000)
- **Isolated credentials** — `CONFIG_PATH` folder excluded from git via `.gitignore`
- **VPN for server access** — use Tailscale or WireGuard instead of exposing SSH to the internet

See [Security](docs/security.md) for full guidance.

---

## Prerequisites

- Docker Engine 20.10+
- Docker Compose v2+
- A 24/7 Linux server (Unraid, NAS, VM, VPS, Raspberry Pi, etc.)
- A Claude account with Remote Control access

---

## Unraid Setup

```bash
ssh root@your-unraid-server
cd /mnt/user/appdata/

git clone https://github.com/LeonardoMacedoCano/ClaudeCodeDock.git claudecodedock
mkdir -p /mnt/user/appdata/claude-config
```

For each project:
```bash
mkdir -p /mnt/user/appdata/projects/homepage
cp /mnt/user/appdata/claudecodedock/.env.example /mnt/user/appdata/projects/homepage/.env
cp /mnt/user/appdata/claudecodedock/docker-compose.yml /mnt/user/appdata/projects/homepage/docker-compose.yml
```

Recommended `.env` for Unraid:
```env
CLAUDE_SOURCE_PATH=/mnt/user/appdata/claudecodedock
CONFIG_PATH=/mnt/user/appdata/claude-config
WORKSPACE_PATH=/mnt/cache/www/myhomepage.com
REMOTE_SESSION_NAME=HomePage
AUTO_START_MODE=remote
TZ=America/Sao_Paulo
```

See the [Unraid Guide](docs/unraid.md) for the complete setup.

---

## Updating Claude Code

```bash
cd /srv/projects/homepage
./scripts/update.sh
```

Backs up credentials, rebuilds the image with `--no-cache` (fetches the latest `@anthropic-ai/claude-code`), restarts. Login is preserved.

---

## Backup

```bash
./scripts/backup.sh                          # Create backup
./scripts/restore.sh --list                  # List backups
./scripts/restore.sh ./backups/backup.tar.gz # Restore
```

---

## Compatibility

| Platform | Status |
|----------|--------|
| Linux x86_64 | Supported |
| Linux ARM64 (Raspberry Pi 4/5) | Supported |
| Unraid 6.10+ | Supported — see [Unraid Guide](docs/unraid.md) |
| Synology DSM | Supported |
| QNAP QTS | Supported |
| TrueNAS Scale | Supported |
| Proxmox (Linux VM) | Supported |

---

## Documentation

| Document | Description |
|----------|-------------|
| [Unraid Guide](docs/unraid.md) | Complete Unraid setup |
| [Docker Reference](docs/docker.md) | Docker commands, volumes, logs |
| [Architecture](docs/architecture.md) | tmux/PID 1 design, data flow, design decisions |
| [Troubleshooting](docs/troubleshooting.md) | Common problems and solutions |
| [Security](docs/security.md) | Credential protection, remote access |

---

## FAQ

**Do I need to log in for every container I create?**

No. Set `CONFIG_PATH` to the same folder in every container. Log in once with the first container. Every other container reads the same credentials and starts already authenticated.

**Can I run many containers simultaneously on the same server?**

Yes. Each container needs a unique `container_name` in `docker-compose.yml`, a unique `REMOTE_SESSION_NAME`, and its own `WORKSPACE_PATH`. `CONFIG_PATH` and `CLAUDE_SOURCE_PATH` are shared.

**What if Remote Control freezes?**

Connect to your server via VPN, SSH in, and run:
```bash
docker exec -it claudecodedock-<name> tmux attach-session -t main
```
Unblock the session, then detach with `Ctrl+B, D`. Remote Control resumes.

**What is `--dangerously-skip-permissions`?**

An official Claude Code flag that skips confirmation prompts before running commands or editing files. Enabled by `CLAUDE_AUTO_APPROVE=true`. Recommended for personal containers where you are the only user.

**Why non-root user?**

Claude Code 2.x blocks `--dangerously-skip-permissions` when run as root (UID 0). ClaudeCodeDock uses the `node` user (UID 1000) to satisfy this requirement and as a security best practice.

**How do I access the terminal if Remote Control is unavailable?**

```bash
# From SSH on the server:
docker exec -it claudecodedock-<name> tmux attach-session -t main

# Disconnect without stopping:
Ctrl+B, D
```

**What happens if the server reboots?**

All containers restart automatically (`restart: unless-stopped`). Every Claude instance comes back authenticated and in Remote Control mode. You reconnect from Claude.ai and everything is where you left it.

---

## Quick Troubleshooting

| Problem | Solution |
|---------|----------|
| Container does not start | `docker compose logs` to see the error |
| Session not appearing in Remote Control | Check `AUTO_START_MODE=remote` and `REMOTE_SESSION_NAME` in `.env` |
| Asks for login every time | Verify `CONFIG_PATH` points to the same folder across containers |
| Remote Control session frozen | SSH to server, `docker exec -it claudecodedock-<name> tmux attach-session -t main`, unblock |
| Permission denied on workspace | `chown -R 1000:1000 /your/workspace/` (UID 1000 = node user) |
| Empty workspace | Check `WORKSPACE_PATH` in `.env` and that the folder exists on host |

See [Troubleshooting Guide](docs/troubleshooting.md) for more.

---

## Legal Notice

ClaudeCodeDock is an independent open source project, not affiliated with Anthropic. Claude Code is a product of Anthropic. All use is subject to the [Anthropic Usage Policy](https://www.anthropic.com/legal/aup).

## License

MIT License
