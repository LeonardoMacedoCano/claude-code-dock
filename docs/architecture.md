# Architecture — ClaudeCodeDock

## Overview

ClaudeCodeDock implements a "persistent process in container" pattern, where Claude Code runs inside a tmux session (PID 1 = tmux) in a Docker container that restarts automatically. The user connects and disconnects via `tmux attach-session` without interrupting the session.

```
+---------------------------------------------------------------+
|                        Host Server                            |
|                  (Linux / Unraid / NAS / VM)                  |
|                                                               |
|  +----------------------------------------------------------+  |
|  |              Docker Engine                               |  |
|  |                                                          |  |
|  |  +------------------------------------------------------+|  |
|  |  |         Container: claude-code-dock                       ||  |
|  |  |         User: node (UID 1000, non-root)              ||  |
|  |  |                                                      ||  |
|  |  |   PID 1: tmux                                        ||  |
|  |  |     +-- session "main" --> claude [args]             ||  |
|  |  |                                                      ||  |
|  |  |         tmux attach-session -t main                  ||  |
|  |  |                    ^                                 ||  |
|  |  |         (connect / disconnect freely)                ||  |
|  |  +------------------------------------------------------+|  |
|  |                                                          |  |
|  +----------------------------------------------------------+  |
|                                                               |
|  +--------------------+    +--------------------------------+  |
|  |  ./config/         |    |  WORKSPACE_PATH                |  |
|  |  (Claude           |    |  (user projects)               |  |
|  |   credentials)     |    |  e.g. /mnt/user/projects       |  |
|  +---------+----------+    +---------------+----------------+  |
|            | volume                        | volume            |
|            v /home/node/.claude            v /workspace        |
|  +----------------------------------------------------------+  |
|  |                     Container                            |  |
|  +----------------------------------------------------------+  |
+---------------------------------------------------------------+
         ^
    SSH / VPN / Local
         ^
+--------------------+
|   User Device      |
|                    |
|  Terminal + SSH    |
|  or local access   |
+--------------------+
```

---

## Components

### 1. Docker Container (`claude-code-dock`)

The core of the system. Contains:

| Component | Version | Role |
|-----------|---------|------|
| Debian Bookworm | Stable LTS | Base OS |
| Node.js LTS | >= 18 | Claude Code runtime |
| `@anthropic-ai/claude-code` | Latest | Main CLI |
| tmux | apt package | PID 1 — hosts the Claude session |
| bash | 5.x | Shell and scripts |

### 2. Non-root user (`node`, UID 1000)

The container runs as the `node` user (UID/GID 1000), not as `root`. This is required because Claude Code 2.x blocks `--dangerously-skip-permissions` when executed as root. The `node:lts-bookworm` base image already includes this user.

### 3. Configuration Volume (`./config`)

Mapped to `/home/node/.claude` inside the container.

Claude Code stores in this directory:
- Authentication credentials
- User settings (`settings.json`)
- Session history
- Context cache

**Why persist it:** Without this volume, the user would need to authenticate again on every container restart.

### 4. Workspace Volume (`$WORKSPACE_PATH`)

Mapped to `/workspace` inside the container.

This is the working directory where the user keeps their projects. It can point to:
- A local directory on the server
- An NFS share
- An Unraid storage pool
- A NAS volume

### 5. Entrypoint (`docker/entrypoint.sh`)

Script executed when the container starts. Responsible for:
1. Displaying banner and variable configuration
2. Validating dependencies
3. Preparing environment and directories
4. Configuring Git and `settings.json`
5. Determining execution mode (interactive/remote/shell)
6. Handing control to the process via `exec tmux new-session ...`

---

## Execution Modes

The container supports three modes, controlled by the `AUTO_START_MODE` variable:

| Mode | PID 1 | Use |
|------|-------|-----|
| `interactive` (default) | `tmux` -> `claude [--dangerously-skip-permissions]` | Interactive terminal via `tmux attach-session` |
| `remote` | `tmux` -> `claude --remote-control` | Remote Control server for external clients |
| `shell` | `bash` | Debug and manual inspection |

---

## Data Flow

### Container Startup

```
docker compose up -d
        |
        v
Docker Engine reads docker-compose.yml
        |
        v
Docker mounts volumes:
  ./config        -> /home/node/.claude
  $WORKSPACE_PATH -> /workspace
        |
        v
Docker runs entrypoint.sh (as user node, UID 1000)
        |
        v
entrypoint.sh reads variables and validates environment
        |
        v
entrypoint.sh determines mode (interactive/remote/shell)
        |
        v
entrypoint.sh executes: exec tmux new-session -s main <cmd> [args]
        |
        v
tmux replaces entrypoint.sh as PID 1
        |
        v
tmux starts Claude Code inside session "main"
        |
        v
Container ready -- connect via: docker exec -it claude-code-dock tmux attach-session -t main
```

### User Connection

```
User runs: docker exec -it claude-code-dock tmux attach-session -t main
        |
        v
tmux connects the terminal to session "main" where Claude is running
        |
        v
User interacts normally
        |
        v
User presses Ctrl+B, D to disconnect (tmux detach)
        |
        v
tmux detaches the client -- session "main" and Claude keep running
        |
        v
Container remains active
```

### Container Restart

```
Host reboots (or container crashes)
        |
        v
Docker Engine starts automatically
(restart: unless-stopped)
        |
        v
Container restarts with volumes already mounted
        |
        v
entrypoint.sh runs again
        |
        v
exec tmux new-session -> Claude Code reads credentials from /home/node/.claude
(persisted in the ./config volume)
        |
        v
Claude starts already authenticated -- no new login required
```

---

## Design Decisions

### Why `exec tmux new-session` and not `tail -f /dev/null`?

`tail -f /dev/null` is a common hack to keep containers "alive". It works, but has serious problems:
- Claude would be a distant child process, unrelated to PID 1
- Docker signals (`SIGTERM`) would not reach Claude
- There is no tmux session to reconnect to
- The container does not stop when Claude stops (unexpected behavior)

With `exec tmux new-session -s main claude`:
- tmux is PID 1 (the main process)
- Signals reach tmux, which forwards them to Claude
- `docker exec -it ... tmux attach-session -t main` connects to the Claude session
- Container stops and restarts correctly when tmux exits

### Why not use `docker attach` directly?

`docker attach` connects to PID 1's stdin/stdout, which is `tmux`. The raw tmux multiplexer output is not useful for interactive use. Instead, `docker exec -it ... tmux attach-session -t main` connects properly to the running Claude session inside tmux.

### Why non-root user (`node`, UID 1000)?

Claude Code 2.x blocks `--dangerously-skip-permissions` when the process runs as root. Using a dedicated user solves this and is a security best practice. We reuse the `node` user already present in the base image to avoid GID conflicts.

### Why `restart: unless-stopped` and not `always`?

`always` would restart the container even after an intentional `docker compose stop`, preventing maintenance. `unless-stopped` respects the operator's conscious decision to stop the container.

### Why `stdin_open: true` and `tty: true`?

Claude Code is a TUI (Text User Interface) application that requires:
- `stdin_open` (`-i`): interactive keyboard input
- `tty` (`-t`): a real terminal for interface rendering

Without these flags, the Claude interface does not render and the experience degrades. tmux also needs a TTY to manage its sessions properly.

### Why `/home/node/.claude` and not `/root/.claude`?

The container runs as the `node` user (non-root). This user's home is `/home/node/`, so Claude Code stores its configuration in `/home/node/.claude/`. This is consistent with the configured user (`ENV HOME=/home/node`) and necessary for `--dangerously-skip-permissions` to work correctly.

---

## Security Model

```
+---------------------------------------------+
|              Boundaries                      |
|                                             |
|  Host filesystem                            |
|    +-- ./config/ -------> /home/node/.claude|
|         (credentials, mode 700)             |
|                                             |
|    +-- WORKSPACE_PATH --> /workspace        |
|         (user projects)                     |
|                                             |
|  Container user: node (UID 1000)            |
|  Network: no exposed ports                  |
|  Interaction: terminal only                 |
|                                             |
+---------------------------------------------+
```

For full security details, see [Security](security.md).

---

## Platform Compatibility

| Platform | Status | Notes |
|----------|--------|-------|
| Linux x86_64 | Supported | Primary platform |
| Linux ARM64 | Supported | Raspberry Pi 4/5, Ampere |
| Unraid 6.x+ | Supported | Via Docker UI or Compose -- see [Unraid Guide](unraid.md) |
| Synology DSM | Supported | Container Manager |
| QNAP QTS | Supported | Container Station |
| Proxmox VM | Supported | Inside Linux VM |
| TrueNAS Scale | Supported | Via Docker Compose |
| macOS | Functional | Local development |
| Windows WSL2 | Functional | Local development |
