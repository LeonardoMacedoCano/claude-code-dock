# Claude Code Dock

**Run Claude Code persistently on a 24/7 server — always on, always authenticated, accessible from any device.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker)](https://www.docker.com/)
[![Unraid](https://img.shields.io/badge/Unraid-Compatible-F15A2C)](https://unraid.net/)

---

## What It Solves

Claude Remote Control requires Claude to already be running on your machine before you connect. Close the terminal, leave home, let the laptop sleep — the session is gone.

**claude-code-dock fixes that.** It runs Claude inside a Docker container on a server that never turns off. Boot, stay running, survive disconnects. Open Claude.ai from anywhere and your sessions are already there.

If a session freezes (Claude stuck waiting for a permission prompt), VPN into your server, attach to the tmux session, unblock it, detach. No physical access needed.

---

## Is This For You?

**Yes, if you:**
- Have a server that stays on 24/7 (homelab, Unraid, NAS, VPS, Raspberry Pi)
- Want Claude Remote Control available from any device without preparing anything in advance
- Want multiple projects each with their own persistent Claude session

**No, if you:**
- Don't have a 24/7 server
- Only use Claude Code on your local machine — just install `@anthropic-ai/claude-code` directly

---

## Example

You have a website running on your server. One container, pointed at the production folder:

```env
REMOTE_SESSION_NAME=HomePage
WORKSPACE_PATH=/srv/www/myhomepage.com
AUTO_START_MODE=remote
```

From Claude.ai Remote Control, select `HomePage` and ask: *"Update the About page with my new contact info."* Claude is running directly on the server, in the production folder, with your files — from your phone, from anywhere.

One server can run any number of containers, each with its own project and session name, all sharing the same Claude login.

---

## Setup

### 1. Clone to your server (once)

```bash
git clone https://github.com/LeonardoMacedoCano/claude-code-dock.git /srv/claude-code-dock
mkdir -p /srv/claude-config
```

`/srv/claude-config` is the shared credentials folder — **all containers point here, you log in only once.**

### 2. Create a project folder

```bash
mkdir -p /srv/projects/homepage
cp /srv/claude-code-dock/.env.example /srv/projects/homepage/.env
cp /srv/claude-code-dock/docker-compose.yml /srv/projects/homepage/docker-compose.yml
```

### 3. Configure `.env`

```env
CONTAINER_NAME=claude-code-dock-homepage
CLAUDE_SOURCE_PATH=/srv/claude-code-dock
CONFIG_BASE_PATH=/srv/claude-code-dock/configs
WORKSPACE_PATH=/srv/www/homepage
AUTO_START_MODE=remote
CLAUDE_AUTO_APPROVE=true
REMOTE_SESSION_NAME=HomePage
CLAUDE_EXTRA_ARGS=
TZ=America/Sao_Paulo
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@email.com
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
GIT_REPO_URL=https://github.com/your-user/your-repo.git
```

### 4. Build and start

```bash
cd /srv/projects/homepage
docker compose build
docker compose up -d
```

### 5. First login (only once, for the first container)

```bash
docker exec -it claude-code-dock-homepage tmux attach-session -t main
```

Complete the authentication flow. Credentials are saved to `CONFIG_BASE_PATH/REMOTE_SESSION_NAME/` (e.g. `/srv/claude-code-dock/configs/HomePage/`). Disconnect with `Ctrl+B, D` — the container keeps running.

For every additional container: copy, set a new `CONTAINER_NAME`, `WORKSPACE_PATH`, and `REMOTE_SESSION_NAME` — same `CONFIG_BASE_PATH`, no login required.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_NAME` | `claude-code-dock` | Docker container name — must be unique per container on the same host |
| `CLAUDE_SOURCE_PATH` | `.` | Path to the claude-code-dock clone on the host |
| `CONFIG_BASE_PATH` | `./configs` | Base directory for per-session config subdirectories — share this across all containers |
| `REMOTE_SESSION_NAME` | `` | Unique session ID — credentials stored at `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` |
| `WORKSPACE_PATH` | `./workspaces` | This container's project folder |
| `AUTO_START_MODE` | `interactive` | `interactive`, `remote`, or `shell` |
| `CLAUDE_AUTO_APPROVE` | `true` | Enables `--dangerously-skip-permissions` |
| `CLAUDE_EXTRA_ARGS` | `` | Extra arguments passed to Claude |
| `TZ` | `UTC` | Container timezone |
| `GIT_USER_NAME` | `` | Name for git commit authorship |
| `GIT_USER_EMAIL` | `` | Email for git commit authorship |
| `GITHUB_TOKEN` | `` | GitHub PAT for push/pull authentication |
| `GIT_REPO_URL` | `` | HTTPS URL of repo to auto-clone into `/workspace` on first start |

---

## Git & GitHub

`GIT_USER_NAME` and `GIT_USER_EMAIL` set your commit identity inside the container. `GITHUB_TOKEN` authenticates push/pull to GitHub — without it, `git push` fails.

**How to create a token:**
1. Go to [github.com/settings/tokens](https://github.com/settings/tokens) → **Generate new token (classic)**
2. Name it (e.g. `claude-code-dock`), select scope **`repo`**, generate and copy
3. Add to `.env`: `GITHUB_TOKEN=ghp_xxx...`

The token is configured on every container start from `.env` — no manual credential commands needed. Never commit `.env` to git (it is already in `.gitignore`).

### Auto-clone on startup

Set `GIT_REPO_URL` to an HTTPS URL and the container clones the repository into `/workspace` automatically on the first start, as long as the workspace is empty.

```env
GIT_REPO_URL=https://github.com/your-user/your-repo.git
```

> **HTTPS only.** SSH URLs (`git@github.com:...`) are not supported — the container has no SSH keys. Always use the `https://` form. Private repos require `GITHUB_TOKEN`.

---

## Execution Modes

| Mode | `AUTO_START_MODE` | Use when |
|------|-------------------|----------|
| remote | `remote` | Main use case — Claude Remote Control from any device |
| interactive | `interactive` | You want Claude in the terminal via SSH |
| shell | `shell` | Debugging the container |

---

## Scripts

```bash
./scripts/install.sh      # Guided initial setup
./scripts/new-session.sh  # Create a new isolated session (.env.<name>)
./scripts/sessions.sh     # List all claude-code-dock containers and their status
./scripts/attach.sh       # Attach to the tmux session where Claude is running
./scripts/shell.sh        # Open a separate bash shell in the container
./scripts/logs.sh         # Stream container logs
./scripts/status.sh       # Show status, credentials, workspace, and backups for a session
./scripts/update.sh       # Rebuild with latest Claude Code, restart
./scripts/backup.sh       # Backup credentials and workspace
./scripts/restore.sh      # Restore from a backup
./scripts/claude.sh       # Run Claude via docker exec (separate session)
./scripts/remote.sh       # Temporary Remote Control session via docker exec
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Container does not start | `docker compose logs` |
| Session not in Remote Control | Check `AUTO_START_MODE=remote` and `REMOTE_SESSION_NAME` |
| Asks for login on every restart | Verify `CONFIG_BASE_PATH` is the same value across all containers |
| Remote Control session frozen | SSH → `docker exec -it <name> tmux attach-session -t main` → unblock |
| `git push` fails | Set `GITHUB_TOKEN` in `.env` |
| Permission denied on workspace | `chown -R 1000:1000 /your/workspace/` on the host |

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
| [Architecture](docs/architecture.md) | tmux/PID 1 design, data flow, technical decisions |
| [Docker Reference](docs/docker.md) | Docker commands, volumes, logs |
| [Unraid Guide](docs/unraid.md) | Complete Unraid setup |
| [Troubleshooting](docs/troubleshooting.md) | Common problems and solutions |
| [Security](docs/security.md) | Credential protection, remote access |

---

claude-code-dock is an independent open source project, not affiliated with Anthropic. [MIT License](LICENSE)
