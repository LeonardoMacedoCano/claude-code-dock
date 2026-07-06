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
    +-- config/                    <- Claude Code credentials

/mnt/cache/projects/               <- workspace (SSD = fast)
    +-- my-project-1/
    +-- my-project-2/
```

**Unraid UI container console:**
- Go to **Docker** -> click the `claude-code-dock` container -> **Console**
- Connects directly to Claude Code (requires the Shell field set to `claude-console` — no slashes)
- To disconnect without stopping: `Ctrl+B` then `D`

**Debug shell (separate process):**
- `./scripts/shell.sh` or `docker exec -it claude-code-dock bash`
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
# Leave CLAUDE_SOURCE_PATH unset — the image builds directly from GitHub.
# Pin a version once tags are available: CLAUDE_DOCK_VERSION=v1.0.0
CLAUDE_DOCK_VERSION=main

# Workspace on SSD cache (faster than the HDD array)
WORKSPACE_PATH=/mnt/cache/projects

# Claude Code credentials
CONFIG_PATH=/mnt/user/appdata/claude-code-dock/config

# Execution mode
AUTO_START_MODE=interactive

# Auto-approve (recommended for personal server)
CLAUDE_AUTO_APPROVE=true

# Timezone
TZ=America/New_York

# Git configuration
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=your@email.com
```

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

### 2.1 — Build the image manually

Via SSH, build the image directly from GitHub — no local clone needed:

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
| Repository | `claude-code-dock:latest` |
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
| Value | true |

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
docker exec -it claude-code-dock tmux attach-session -t main
```

To disconnect without stopping Claude: `Ctrl+B` then `D`.

### Via Unraid Console (web UI)

1. Open the Unraid panel
2. Go to **Docker**
3. Make sure the **Shell** field in the template is set to `claude-console` (no slashes)
4. Click the `claude-code-dock` container -> **Console**

The Console opens directly into the Claude Code session. To disconnect: `Ctrl+B` then `D`.

### Via debug shell (separate process)

To inspect the container without interfering with Claude Code:

```bash
./scripts/shell.sh
# or directly:
docker exec -it claude-code-dock bash
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
|       +-- config/                   <- Claude Code credentials
|       |   +-- settings.json        (created after login)
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

The **CA Appdata Backup/Restore** plugin can automatically back up the entire `appdata` folder, including `claude-code-dock/config`.

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

Unraid manages permissions differently. The container runs as the `node` user (UID 1000). Check:

```bash
# Check folder ownership
ls -la /mnt/cache/ | grep projects

# Fix permissions if needed (UID 1000 = node)
chmod 755 /mnt/cache/projects
chown -R 1000:1000 /mnt/cache/projects

# Alternative: open permissions (fine for personal homelab)
chmod 777 /mnt/cache/projects
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

### Docker UI shows the container as "unhealthy"

claude-code-dock does not implement an HTTP health check because it is an interactive terminal process. The status in the Unraid UI may show as "unhealthy" — this is expected and does not indicate a real problem.

To check the actual status:

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

## Community Applications Template (Future)

An XML template for Community Applications is planned for future versions of claude-code-dock, allowing one-click installation via CA on Unraid. Until then, use Method 1 (Docker Compose) or Method 2 (Docker UI).
