# Getting Started — claude-code-dock

Full walkthrough: pick your `.env` profile, choose single- vs multi-project
workflow, then follow the step-by-step setup. If you just want the 30-second
pitch first, see the [README](../README.md).

**Jump to:** [Which Setup Is Yours?](#which-setup-is-yours) · [One Container or Many?](#one-container-or-many-pick-your-workflow) · [Setup](#setup) · [Execution Modes](#execution-modes) · [Scripts](#scripts)

---

## Which Setup Is Yours?

Every `.env` boils down to one of four combinations. Find yours, copy the snippet, then follow [Setup](#setup) below with those values.

### 1. Default — simplest, no GitHub

Just want Claude running persistently and reachable from a terminal. No git integration inside the container.

```env
REMOTE_SESSION_NAME=my-project
WORKSPACE_PATH=/srv/www/my-project
CONFIG_BASE_PATH=/srv/claude-config
```

That's it — `AUTO_START_MODE` defaults to `interactive`, the image is pulled from GHCR, no `GIT_*` vars needed.

### 2. Remote Control — same, but from any device

Same as #1, plus Remote Control so you can drive it from claude.ai on your phone or laptop without SSHing in first.

```env
REMOTE_SESSION_NAME=my-project
WORKSPACE_PATH=/srv/www/my-project
CONFIG_BASE_PATH=/srv/claude-config
AUTO_START_MODE=remote
```

### 3. With GitHub — commit and push from inside the container

Either of the above, plus a git identity and (optionally) push/pull authentication so Claude can commit and open PRs on your behalf.

```env
REMOTE_SESSION_NAME=my-project
WORKSPACE_PATH=/srv/www/my-project
CONFIG_BASE_PATH=/srv/claude-config
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@email.com
GITHUB_TOKEN_FILE=/srv/claude-secrets/github_token
```

`GITHUB_TOKEN_FILE` is a **host path** to a token file, never a literal token in `.env` — full walkthrough in [Git & GitHub Integration](git-integration.md).

### 4. Contributor — building claude-code-dock itself from a local clone

Changing claude-code-dock's Dockerfile/scripts/entrypoint, not just using it — want the container built from your working tree instead of the published image.

```env
CLAUDE_SOURCE_PATH=.
```

Combine freely with any of profiles 1–3 above — this only changes where the image is built from. See [docs/docker.md#local-development](docker.md#local-development) for the rebuild caveats, and [CONTRIBUTING.md](../CONTRIBUTING.md) for the full dev workflow.

---

## One Container or Many? Pick Your Workflow

**A. Just one project → plain `docker-compose.yml` + `.env`** (the [Setup](#setup) walkthrough below). Each new project is a new folder with its own `docker-compose.yml`/`.env` copy, started with plain `docker compose up -d`.

**B. Several projects from one clone → the session scripts** (`new-session.sh` / `session-up.sh` / `sessions.sh`). One clone manages N containers, each bound to its own `.env.<name>` file and its own Compose project name:

```bash
./scripts/new-session.sh homepage    # creates .env.homepage from .env/.env.example
nano .env.homepage                   # set WORKSPACE_PATH, REMOTE_SESSION_NAME, etc.
./scripts/session-up.sh homepage     # docker compose --env-file .env.homepage -p claude-homepage up -d
./scripts/sessions.sh                # lists every claude-code-dock container and its status
```

Reach for **B** once you're managing more than two or three projects. Both workflows produce the same kind of container and can coexist on the same host.

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
REMOTE_SESSION_NAME=HomePage
TZ=America/Sao_Paulo
```

That covers Profiles 1–2 above. Adding GitHub integration or pinning a build source? See [Which Setup Is Yours?](#which-setup-is-yours) for what else to add, or the full [Environment Variables reference](docker.md#environment-variables) for every option.

### 3. Pull and start

```bash
cd /srv/projects/homepage
docker compose pull
docker compose up -d
```

> Prefer the convenience scripts (`install.sh`, `attach.sh`, `backup.sh`, ...)? Clone the repository instead — see [Scripts](#scripts) below. They still work with `CLAUDE_SOURCE_PATH` unset, since they pull the prebuilt image rather than needing a local clone.

### 4. First login (only once, for the first container)

```bash
docker exec -it --user node claude-code-dock-homepage tmux attach-session -t main
```

Complete the authentication flow. Credentials are saved to `CONFIG_BASE_PATH/REMOTE_SESSION_NAME/` (e.g. `/srv/claude-config/HomePage/`). Disconnect with `Ctrl+B, D` — the container keeps running.

For every additional container: copy, set a new `CONTAINER_NAME`, `WORKSPACE_PATH`, and `REMOTE_SESSION_NAME` — same `CONFIG_BASE_PATH`, no login required.

---

## Execution Modes

| Mode | `AUTO_START_MODE` | Use when |
|------|-------------------|----------|
| remote | `remote` | Main use case — Claude Remote Control from any device |
| interactive | `interactive` | You want Claude in the terminal via SSH |
| shell | `shell` | Debugging the container |

---

## Scripts

Available after cloning the repo (each supports `-h`/`--help` for details):

```bash
./scripts/install.sh      # Guided initial setup
./scripts/new-session.sh  # Create a new isolated session (.env.<name>)
./scripts/session-up.sh   # Start a session by name
./scripts/sessions.sh     # List all claude-code-dock containers and their status
./scripts/attach.sh       # Attach to the tmux session where Claude is running
./scripts/shell.sh        # Open a separate bash shell in the container
./scripts/logs.sh         # Stream container logs (--app for the persistent startup log)
./scripts/status.sh       # Show status, credentials, workspace, and backups
./scripts/watchdog.sh     # Restart the container if Docker reports it unhealthy (run via cron)
./scripts/update.sh       # Pull latest image (or rebuild if CLAUDE_SOURCE_PATH is set), restart
./scripts/backup.sh       # Backup credentials and workspace (--encrypt for GPG AES256)
./scripts/restore.sh      # Restore from a backup
./scripts/claude.sh       # Run Claude via docker exec (separate session)
./scripts/remote.sh       # Temporary Remote Control session via docker exec
```

`install.sh` also accepts `--with-watchdog` and `--with-backup-cron` to set up
host crontab entries for auto-restart-on-unhealthy and daily backups,
respectively — both idempotent, safe to pass on a later re-run. See
[Docker Reference: Watchdog](docker.md#watchdog) and
[Docker Reference: Backups](docker.md#backups).

---

[← Back to README](../README.md)
