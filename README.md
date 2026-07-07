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

## One Container or Many? Pick Your Workflow

Two ways to run claude-code-dock, both valid — pick based on how many projects you're pointing it at:

**A. Just one project → plain `docker-compose.yml` + `.env` (the [Setup](#setup) walkthrough below).**
Each new project is a new folder with its own `docker-compose.yml`/`.env` copy, started with plain `docker compose up -d`. Simple, explicit, no extra tooling to learn.

**B. Several projects from one clone → the session scripts (`new-session.sh` / `session-up.sh` / `sessions.sh`).**
Instead of copying the whole project directory per container, one clone of claude-code-dock manages N containers, each bound to its own `.env.<name>` file and its own Compose project name (so `docker compose` commands never accidentally target the wrong session):

```bash
./scripts/new-session.sh homepage    # creates .env.homepage from .env/.env.example
nano .env.homepage                   # set WORKSPACE_PATH, REMOTE_SESSION_NAME, etc.
./scripts/session-up.sh homepage     # docker compose --env-file .env.homepage -p claude-homepage up -d
./scripts/sessions.sh                # lists every claude-code-dock container and its status
```

Reach for **B** once you're managing more than two or three projects — it keeps each session's `.env` file and Compose project isolated without you needing to remember which folder belongs to which container. Both workflows produce the same kind of container and can coexist on the same host; they're just two ways of generating the same `docker-compose.yml` + `.env` inputs.

---

## Setup

No local clone of this repository is required — `docker compose pull` fetches the prebuilt, CI-published image directly from GHCR. You only need two files on your server: `docker-compose.yml` and `.env`.

### 1. Create a project folder

```bash
mkdir -p /srv/projects/homepage
curl -o /srv/projects/homepage/docker-compose.yml https://raw.githubusercontent.com/LeonardoMacedoCano/claude-code-dock/main/docker-compose.yml
curl -o /srv/projects/homepage/.env https://raw.githubusercontent.com/LeonardoMacedoCano/claude-code-dock/main/.env.example
mkdir -p /srv/claude-config
```

`/srv/claude-config` is the shared credentials folder — **all containers point here, you log in only once.**

### 2. Configure `.env`

```env
CONTAINER_NAME=claude-code-dock-homepage
CONFIG_BASE_PATH=/srv/claude-config
WORKSPACE_PATH=/srv/www/homepage
AUTO_START_MODE=remote
CLAUDE_AUTO_APPROVE=false
REMOTE_SESSION_NAME=HomePage
CLAUDE_EXTRA_ARGS=
TZ=America/Sao_Paulo
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@email.com
GITHUB_TOKEN_FILE=/srv/claude-secrets/github_token
GIT_REPO_URL=https://github.com/your-user/your-repo.git
```

Leave `CLAUDE_SOURCE_PATH` empty (default) so `docker compose pull` fetches the prebuilt image from GHCR — pin a version with `CLAUDE_DOCK_IMAGE` (e.g. a specific tag) if needed. Only set `CLAUDE_SOURCE_PATH` if you have a local clone of claude-code-dock you want to build from instead.

### 3. Pull and start

```bash
cd /srv/projects/homepage
docker compose pull
docker compose up -d
```

> Prefer the convenience scripts (`install.sh`, `attach.sh`, `backup.sh`, ...)? Clone the repository instead — see [Scripts](#scripts) below. The scripts still work with `CLAUDE_SOURCE_PATH` unset, since they pull the prebuilt image rather than needing a local clone.

### 4. First login (only once, for the first container)

```bash
docker exec -it claude-code-dock-homepage tmux attach-session -t main
```

Complete the authentication flow. Credentials are saved to `CONFIG_BASE_PATH/REMOTE_SESSION_NAME/` (e.g. `/srv/claude-config/HomePage/`). Disconnect with `Ctrl+B, D` — the container keeps running.

For every additional container: copy, set a new `CONTAINER_NAME`, `WORKSPACE_PATH`, and `REMOTE_SESSION_NAME` — same `CONFIG_BASE_PATH`, no login required.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CONTAINER_NAME` | `claude-code-dock` | Docker container name — must be unique per container on the same host |
| `CLAUDE_DOCK_IMAGE` | `ghcr.io/leonardomacedocano/claude-code-dock:latest` | Prebuilt image pulled by default — override to pin a tag or use your own fork's registry |
| `CLAUDE_DOCK_VERSION` | `main` | Branch/tag of claude-code-dock to build from, when building instead of pulling |
| `CLAUDE_SOURCE_PATH` | `` | Local claude-code-dock clone to build from instead of pulling the prebuilt image (advanced) |
| `CONFIG_BASE_PATH` | `./configs` | Base directory for per-session config subdirectories — share this across all containers |
| `REMOTE_SESSION_NAME` | `` | Unique session ID — credentials stored at `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` |
| `WORKSPACE_PATH` | `./workspaces` | This container's project folder |
| `AUTO_START_MODE` | `interactive` | `interactive`, `remote`, or `shell` |
| `CLAUDE_AUTO_APPROVE` | `false` | Enables `--dangerously-skip-permissions` — only turn on once you trust the workspace |
| `CLAUDE_EXTRA_ARGS` | `` | Extra arguments passed to Claude — quoted substrings with spaces are now supported, e.g. `--append-system-prompt "be terse"` |
| `TZ` | `UTC` | Container timezone |
| `GIT_USER_NAME` | `` | Name for git commit authorship |
| `GIT_USER_EMAIL` | `` | Email for git commit authorship |
| `GITHUB_TOKEN_FILE` | `` | HOST path to a file holding your GitHub PAT — auto-mounted into the container, no manual volume editing needed |
| `GIT_REPO_URL` | `` | HTTPS URL of repo to auto-clone into `/workspace` on first start |

---

## Git & GitHub

`GIT_USER_NAME` and `GIT_USER_EMAIL` set your commit identity inside the container. `GITHUB_TOKEN_FILE` authenticates push/pull to GitHub — without it, `git push` fails (public repos and read-only clones still work).

**Setup:**
1. Create a token: [github.com/settings/tokens](https://github.com/settings/tokens) → **Generate new token (classic)** → name it (e.g. `claude-code-dock`) → scope **`repo`** → generate and copy.
2. Save it to a file **on the host** (not in `.env`):
   ```bash
   mkdir -p /srv/claude-secrets
   echo -n "ghp_xxx..." > /srv/claude-secrets/github_token
   chmod 600 /srv/claude-secrets/github_token
   ```
3. Point `.env` at it:
   ```env
   GITHUB_TOKEN_FILE=/srv/claude-secrets/github_token
   ```
4. `docker compose up -d` (or `--force-recreate` if the container is already running).

`docker-compose.yml` mounts that file automatically, read-only, into the container — no volume editing, no manual credential commands. Leave `GITHUB_TOKEN_FILE` empty to skip GitHub auth entirely; the compose file mounts a harmless `/dev/null` in that case, so nothing breaks either way.

**Note:** the token's value never sits in `.env`, a `docker-compose.yml environment:` line, or the host shell's process environment — only the file path does. The file's *content* is still readable via `docker exec <container> cat /run/secrets/github_token` by anyone with Docker daemon access on this host, same trust boundary as any other bind-mounted file. See [Security](docs/security.md#credential-protection) for the full threat model.

### Auto-clone on startup

Set `GIT_REPO_URL` to an HTTPS URL and the container clones the repository into `/workspace` automatically on the first start, as long as the workspace is empty.

```env
GIT_REPO_URL=https://github.com/your-user/your-repo.git
```

> **HTTPS only.** SSH URLs (`git@github.com:...`) are not supported — the container has no SSH keys. Always use the `https://` form. Private repos require `GITHUB_TOKEN_FILE`.

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
./scripts/session-up.sh   # Start a session by name (binds .env.<name> + its own Compose project)
./scripts/sessions.sh     # List all claude-code-dock containers and their status
./scripts/attach.sh       # Attach to the tmux session where Claude is running
./scripts/shell.sh        # Open a separate bash shell in the container
./scripts/logs.sh         # Stream container logs (--app for the persistent startup log)
./scripts/status.sh       # Show status, credentials, workspace, and backups for a session
./scripts/watchdog.sh     # Restart the container if Docker reports it unhealthy (run via cron)
./scripts/update.sh       # Pull latest Claude Code image (or rebuild if CLAUDE_SOURCE_PATH is set), restart
./scripts/backup.sh       # Backup credentials and workspace (--encrypt for GPG AES256)
./scripts/restore.sh      # Restore from a backup
./scripts/claude.sh       # Run Claude via docker exec (separate session)
./scripts/remote.sh       # Temporary Remote Control session via docker exec
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Container does not start | `docker compose logs` |
| `docker logs` / Unraid Logs tab shows nothing or terminal garbage | Expected once Claude starts (PID 1 is a tmux TUI) — use `./scripts/logs.sh --app` |
| Session not in Remote Control | Check `AUTO_START_MODE=remote` and `REMOTE_SESSION_NAME` |
| Asks for login on every restart | Verify `CONFIG_BASE_PATH` is the same value across all containers |
| Remote Control session frozen | SSH → `docker exec -it <name> tmux attach-session -t main` → unblock |
| Container running but reports `unhealthy` and `restart: unless-stopped` never kicks in | Docker only auto-restarts on exit, not on `unhealthy` — run `./scripts/watchdog.sh` (see `--help` for a cron one-liner) |
| `git push` fails | Set `GITHUB_TOKEN_FILE` in `.env` to a host file containing your PAT |
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
