# Unraid Guide — claude-code-dock

## Overview

Unraid is one of the most popular platforms for homelabs and personal NAS systems. This guide covers two ways to run claude-code-dock on Unraid:

1. **Via Docker Compose** (recommended for technical users)
2. **Via Unraid Docker UI** (for users who prefer the Unraid GUI)

---

## Recommended Experience for Unraid Users

For the best claude-code-dock experience on Unraid:

1. **Install via Docker Compose** (Method 1 below)
2. **Connect via SSH** + `./scripts/attach.sh` (or use the Unraid Console)
3. **Workspace on SSD cache** for better I/O performance
4. **Config in appdata** for automatic backup with CA Appdata Backup

```
Recommended structure on Unraid:

/mnt/user/appdata/claude-code-dock/     <- claude-code-dock project
    +-- Dockerfile
    +-- docker-compose.yml
    +-- .env
    +-- configs/                   <- Claude Code credentials (CONFIG_BASE_PATH)
        +-- <session>/             <- one subfolder per REMOTE_SESSION_NAME

/mnt/cache/projects/               <- workspace (SSD = fast)
    +-- my-project-1/
    +-- my-project-2/
```

**Unraid UI container console:**
- Go to **Docker** -> click the `claude-code-dock` container -> **Console**
- Connects directly to Claude Code (requires the Shell field set to `claude-console` — no slashes)
- To disconnect without stopping: `Ctrl+B` then `D`

**Debug shell (separate process):**
- `./scripts/shell.sh` or `docker exec -it --user node claude-code-dock bash`
- Opens a separate bash shell without interfering with Claude Code

---

## Prerequisites

- Unraid 6.10 or later
- Docker enabled (enabled by default on Unraid)
- SSH access to the Unraid server
- A projects folder on the array or cache

---

## Method 1 — Docker Compose (Recommended)

### 1.1 — Enable Docker Compose on Unraid

Unraid 6.12+ includes native Docker Compose support. For earlier versions, install the **Docker Compose Manager** plugin via Community Applications.

To verify it is available:

```bash
# SSH into the Unraid server
ssh root@your-unraid-server

# Check if docker compose is available
docker compose version
```

### 1.2 — Choose a location for the project files

On Unraid, store claude-code-dock configuration files in the `appdata` share:

```
/mnt/user/appdata/claude-code-dock/
```

This is the standard Unraid convention for persistent application data.

### 1.3 — Clone the project

```bash
# SSH into Unraid
ssh root@your-unraid-server

# Navigate to appdata
cd /mnt/user/appdata/

# Clone the project
git clone https://github.com/LeonardoMacedoCano/claude-code-dock.git claude-code-dock

# Enter the folder
cd claude-code-dock
```

### 1.4 — Configure .env

```bash
# Copy the example file
cp .env.example .env

# Edit with nano
nano .env
```

Typical configuration for Unraid:

```env
# Leave CLAUDE_SOURCE_PATH unset — `docker compose pull` fetches the prebuilt
# image from GHCR directly. Pin a tag with CLAUDE_DOCK_TAG once tagged
# releases are available, e.g. CLAUDE_DOCK_TAG=v1.0.0
CLAUDE_DOCK_VERSION=main

# Workspace on SSD cache (faster than the HDD array)
WORKSPACE_PATH=/mnt/cache/projects

# Base directory for per-session config subdirectories.
# Credentials for THIS container end up at CONFIG_BASE_PATH/REMOTE_SESSION_NAME.
CONFIG_BASE_PATH=/mnt/user/appdata/claude-code-dock/configs

# Required. Isolates this container's credentials from any other instance —
# two containers must never share the same REMOTE_SESSION_NAME.
REMOTE_SESSION_NAME=my-session

# Execution mode
AUTO_START_MODE=interactive

# Auto-approve — false asks for approval before each action (recommended
# default); set to true only once you trust the workspace this points at.
CLAUDE_AUTO_APPROVE=false

# Timezone
TZ=America/New_York

# Git configuration
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=your@email.com
```

> **Coming from an older setup with a flat `CONFIG_PATH`?** That variable was
> replaced by `CONFIG_BASE_PATH` + `REMOTE_SESSION_NAME` so multiple
> containers can safely share one credentials root. Migrate existing
> credentials into the new per-session layout:
> ```bash
> mkdir -p /mnt/user/appdata/claude-code-dock/configs
> mv /mnt/user/appdata/claude-code-dock/config \
>    /mnt/user/appdata/claude-code-dock/configs/my-session
> chown -R 1000:1000 /mnt/user/appdata/claude-code-dock/configs
> ```
> If `CONFIG_BASE_PATH` is left unset, it silently falls back to `./configs`
> (relative to wherever `docker compose` runs from) — a common source of the
> container restarting without ever showing readable logs, since Docker then
> creates that directory owned by root, which UID 1000 (`node`) cannot write
> to. As of the current entrypoint, this now fails fast with a clear
> `chown` instruction printed to `docker logs` instead of looping silently —
> see [troubleshooting.md](troubleshooting.md#container-restart-loop).
>
> This specific manual `chown` is only needed for a one-time migration like
> the one above. For every new `REMOTE_SESSION_NAME` you create from here
> on — including via the Compose Manager plugin's own "Compose Up", not just
> `./scripts/new-session.sh` — `docker-compose.yml`'s `claude-code-dock-init`
> service chowns that session's config directory automatically before the
> main container starts, so this shouldn't come up again.

### 1.5 — Create the workspace directory

```bash
# Create the projects folder if it does not exist
mkdir -p /mnt/cache/projects

# Check permissions
ls -la /mnt/cache/projects
```

### 1.6 — Install and start

```bash
# Run installation
chmod +x scripts/install.sh
./scripts/install.sh
```

### 1.7 — Configure automatic startup on boot

Unraid starts Docker automatically after the array boots. With `restart: unless-stopped`, the container will start automatically.

To ensure Docker Compose starts after boot, add a User Script via the **User Scripts plugin**:

```bash
#!/bin/bash
# Script: Start claude-code-dock
# Trigger: Array Started

cd /mnt/user/appdata/claude-code-dock
docker compose up -d
```

---

## Method 2 — Unraid Docker UI

### 2.1 — Pull the prebuilt image

No SSH or manual build needed — the **Repository** field in step 2.2 below
(`ghcr.io/leonardomacedocano/claude-code-dock:latest`) is enough for Unraid to
pull the image itself when you click **Apply**. Only build manually via SSH if
you need an unreleased change to claude-code-dock itself:

```bash
ssh root@your-unraid-server
docker build -t claude-code-dock:latest https://github.com/LeonardoMacedoCano/claude-code-dock.git#main
```

### 2.2 — Add container via UI

In the Unraid panel:

1. Go to **Docker** -> **Add Container**
2. Fill in the fields:

| Field | Value |
|-------|-------|
| Name | `claude-code-dock` |
| Repository | `ghcr.io/leonardomacedocano/claude-code-dock:latest` |
| Network Type | `bridge` |
| Console shell command | `claude-console` |

### 2.3 — Configure volumes

Click **Add another Path, Port, Variable, Label or Device**:

**Volume 1 — Workspace:**
| Field | Value |
|-------|-------|
| Config Type | Path |
| Name | Workspace |
| Container Path | `/workspace` |
| Host Path | `/mnt/cache/projects` |
| Access Mode | Read/Write |

**Volume 2 — Claude Configuration:**
| Field | Value |
|-------|-------|
| Config Type | Path |
| Name | Claude Config |
| Container Path | `/home/node/.claude` |
| Host Path | `/mnt/user/appdata/claude-code-dock/config` |
| Access Mode | Read/Write |

### 2.4 — Configure environment variables

**Variable 1:**
| Field | Value |
|-------|-------|
| Config Type | Variable |
| Name | AUTO_START_MODE |
| Key | AUTO_START_MODE |
| Value | interactive |

**Variable 2:**
| Field | Value |
|-------|-------|
| Config Type | Variable |
| Name | CLAUDE_AUTO_APPROVE |
| Key | CLAUDE_AUTO_APPROVE |
| Value | false |

**Variable 3:**
| Field | Value |
|-------|-------|
| Config Type | Variable |
| Name | TZ |
| Key | TZ |
| Value | America/New_York |

**Variable 4:**
| Field | Value |
|-------|-------|
| Config Type | Variable |
| Name | TERM |
| Key | TERM |
| Value | xterm-256color |

### 2.5 — Extra settings

| Field | Value |
|-------|-------|
| Extra Parameters | `--interactive --tty` |
| Restart Policy | `unless-stopped` |

Click **Apply** to create the container.

---

## Connecting to Claude Code on Unraid

### Via SSH terminal (recommended)

```bash
# SSH into the Unraid server
ssh root@your-unraid-server

# Connect to Claude Code
./scripts/attach.sh
# or directly:
docker exec -it --user node claude-code-dock tmux attach-session -t main
```

To disconnect without stopping Claude: `Ctrl+B` then `D`.

### Via Unraid Console (web UI)

1. Open the Unraid panel
2. Go to **Docker**
3. Make sure the **Shell** field in the template is set to `claude-console` (no slashes)
4. Click the `claude-code-dock` container -> **Console**

The Console opens directly into the Claude Code session. To disconnect: `Ctrl+B` then `D`.

### About the "Logs" tab in the Docker UI

Unraid's **Logs** button just runs `docker logs`, which shows PID 1's raw
stdout. Since PID 1 is tmux running Claude Code as a full-screen TUI, that tab
will look empty or garbled once the session starts — it is not able to show
scrolling log lines from an interactive terminal app. This is expected; see
[troubleshooting.md](troubleshooting.md#logs-problems). For a clean, persistent
startup log instead, run `./scripts/logs.sh --app` over SSH, or read
`./configs/<session>/logs/dock.log` directly — it lives in the bind-mounted
config folder shown above.

### Via debug shell (separate process)

To inspect the container without interfering with Claude Code:

```bash
./scripts/shell.sh
# or directly:
docker exec -it --user node claude-code-dock bash
```

---

## Recommended Directory Structure on Unraid

```
/mnt/user/
+-- appdata/
|   +-- claude-code-dock/                   <- claude-code-dock project
|       +-- docker-compose.yml
|       +-- Dockerfile
|       +-- .env
|       +-- configs/                  <- CONFIG_BASE_PATH
|       |   +-- <session>/            <- REMOTE_SESSION_NAME, one per container
|       |       +-- settings.json    (created after login)
|       +-- docker/
|       |   +-- entrypoint.sh
|       +-- scripts/
|
+-- (array -- for backup, not for workspace)

/mnt/cache/
+-- projects/                         <- Workspace (SSD = fast)
    +-- my-project-1/
    +-- my-project-2/
    +-- my-project-3/
```

### Why use `/mnt/user/appdata`?

The `appdata` directory on Unraid is the convention for persistent application data. Advantages:
- Automatically excluded from unnecessary media backups
- Included in Unraid configuration backups
- Compatible with plugins like **CA Appdata Backup/Restore**
- Can be placed on cache for better performance

### Why keep the workspace on the SSD cache?

The Unraid array uses HDDs that can be slow for intensive I/O on projects (reading/writing many small files). The SSD cache is much faster for this type of operation.

---

## Backup on Unraid

### Via project script

```bash
# SSH into Unraid
ssh root@your-unraid-server
cd /mnt/user/appdata/claude-code-dock

# Backup Claude configuration
./scripts/backup.sh --output /mnt/user/backups/claude-code-dock
```

### Via CA Appdata Backup/Restore

The **CA Appdata Backup/Restore** plugin can automatically back up the entire `appdata` folder, including `claude-code-dock/configs`.

Configure the plugin to include:
```
/mnt/user/appdata/claude-code-dock/
```

---

## Updating on Unraid

```bash
# SSH into Unraid
ssh root@your-unraid-server
cd /mnt/user/appdata/claude-code-dock

# Update (automatically backs up first)
./scripts/update.sh
```

---

## Unraid-Specific Troubleshooting

### "Permission denied" when accessing the workspace

Unraid manages permissions differently. The container runs as the `node` user (UID/GID 1000 by default). Check:

```bash
# Check folder ownership
ls -la /mnt/cache/ | grep projects

# Fix permissions if needed (UID 1000 = node)
chmod 755 /mnt/cache/projects
chown -R 1000:1000 /mnt/cache/projects

# Alternative: open permissions (fine for personal homelab)
chmod 777 /mnt/cache/projects

# Alternative: instead of chowning the host folder, set PUID/PGID in .env to
# match whatever UID/GID your Unraid share is actually owned by (check with
# `ls -la` above) and restart -- the container remaps its internal 'node'
# account to match instead:
#   PUID=99   # Unraid's own 'nobody' user, common on default shares
#   PGID=100  # Unraid's own 'users' group
```

### Container does not start after array reboot

If the array takes time to mount, Docker may try to start the container before the volume is available. Solutions:

1. Use the **User Scripts plugin** to start after the array is ready
2. Configure a delay in the startup script:

```bash
#!/bin/bash
# Wait for array to be available
sleep 30
cd /mnt/user/appdata/claude-code-dock
docker compose up -d
```

### Compose Manager plugin's "Compose Up"/"Update Stack" fails with a raw "Conflict... name is already in use" error

The Compose Manager plugin calls `docker compose pull`/`up` directly, not
`./scripts/update.sh` — so the friendlier, re-worded message those scripts
give for a `CONTAINER_NAME` collision never kicks in here; you get Docker's
raw daemon error instead. This almost always means two stacks (e.g. a
"prod" and a "dev/test" copy) have the same `CONTAINER_NAME` in their
`.env`. See
[troubleshooting.md](troubleshooting.md#up-fails-after-a-successful-buildpull--conflict-the-container-name--is-already-in-use)
for the fix — set a unique `CONTAINER_NAME` per stack's `.env`.

### Docker UI shows the container as "unhealthy"

claude-code-dock's `HEALTHCHECK` isn't an HTTP check (there's no server to
probe) — it verifies the tmux `main` session exists and its pane isn't dead
(interactive/remote), or that PID 1 is bash (shell mode). A genuine
"unhealthy" status means the Claude Code process crashed or exited inside the
session, not a false positive. Check what's actually happening before
assuming it's cosmetic:

```bash
docker ps --filter name=claude-code-dock
docker logs --tail 20 claude-code-dock
```

### Slow workspace (using array HDD)

```bash
# Check if workspace is on HDD
df -h /mnt/user/projects

# Move to SSD cache
WORKSPACE_PATH=/mnt/cache/projects
```

Set the `projects` share to **Use Cache: Yes** in the Unraid panel to automatically use the SSD cache.

---

## Community Applications Template

A CA-compatible XML template ships at [`unraid/claude-code-dock.xml`](../unraid/claude-code-dock.xml). It hasn't been submitted to the official CA feed yet (that requires a hosted icon and a review PR against Unraid's Community Applications repo), but you can use it today without waiting for that:

1. Go to **Docker** -> **Add Container**
2. At the bottom, switch **Template** to **"Load a template from a URL or local path"**
3. Point it at the raw file, e.g.:
   `https://raw.githubusercontent.com/LeonardoMacedoCano/claude-code-dock/main/unraid/claude-code-dock.xml`
4. Review the fields it pre-fills (workspace path, config path, `REMOTE_SESSION_NAME`, etc. — same variables as [Method 2](#22--add-container-via-ui) above) and click **Apply**

For a second session, repeat with a different container **Name**, a different **Claude Config** host path, and a different `REMOTE_SESSION_NAME` — same isolation pattern as the Compose-based [Multiple Instances](docker.md#multiple-instances) setup via `new-session.sh`/`session-up.sh`.

Until this is in the official CA feed, Method 1 (Docker Compose) or Method 2 (manual Docker UI) remain the more discoverable options for most users.
