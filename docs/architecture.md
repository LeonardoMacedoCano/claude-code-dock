# Architecture — claude-code-dock

## Overview

claude-code-dock implements a "persistent process in container" pattern, where Claude Code runs inside a tmux session (PID 1 = tmux) in a Docker container that restarts automatically. The user connects and disconnects via `tmux attach-session` without interrupting the session.

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
|  +--------------------------+    +--------------------------------+  |
|  |  CONFIG_BASE_PATH/       |    |  WORKSPACE_PATH                |  |
|  |  REMOTE_SESSION_NAME/    |    |  (user projects)               |  |
|  |  (Claude credentials)    |    |  e.g. /mnt/user/projects       |  |
|  +-------------+------------+    +---------------+----------------+  |
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

### 2. Non-root user (`node`, UID/GID 1000 by default, remappable via `PUID`/`PGID`)

The actual long-running process (bash/tmux/claude) always runs as the `node` user, not as `root`. This is required because Claude Code 2.x blocks `--dangerously-skip-permissions` when executed as root. The `node:lts-bookworm` base image already includes this user at UID/GID 1000.

The image itself starts as root by default, though — `entrypoint.sh`'s first block uses that to remap `node` to `PUID`/`PGID` (set them in `.env` if your host user isn't UID/GID 1000) via `usermod`/`groupmod`, then immediately drops privilege via `setpriv` before doing anything else. `PUID`/`PGID=0` is refused. See [Security](security.md) and `CLAUDE.md`'s "Non-root user" section for the full mechanism.

### 3. Configuration Volume (`CONFIG_BASE_PATH/REMOTE_SESSION_NAME`)

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
2. Validating dependencies (the `claude` binary)
3. Validating configuration (`AUTO_START_MODE` value, and that the config
   and workspace directories are writable by UID 1000) — on failure, prints
   a fatal error and holds PID 1 instead of exiting, so `restart:
   unless-stopped` doesn't turn it into an unreadable restart loop
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
Docker mounts volumes for the main service:
  $CONFIG_BASE_PATH/$REMOTE_SESSION_NAME -> /home/node/.claude
  $WORKSPACE_PATH                        -> /workspace
        |
        v
Docker runs entrypoint.sh (as user node, UID 1000)
        |
        v
entrypoint.sh reads variables and validates configuration
(fatal + hold on sleep infinity if AUTO_START_MODE is invalid, or the
 config/workspace directories aren't writable by UID 1000 -- see below)
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
Container ready -- connect via: docker exec -it --user node claude-code-dock tmux attach-session -t main
```

### User Connection

```
User runs: docker exec -it --user node claude-code-dock tmux attach-session -t main
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
(persisted in the CONFIG_BASE_PATH/REMOTE_SESSION_NAME volume)
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
- `docker exec -it --user node ... tmux attach-session -t main` connects to the Claude session
- Container stops and restarts correctly when tmux exits

### Why not use `docker attach` directly?

`docker attach` connects to PID 1's stdin/stdout, which is `tmux`. The raw tmux multiplexer output is not useful for interactive use. Instead, `docker exec -it --user node ... tmux attach-session -t main` connects properly to the running Claude session inside tmux (`--user node` matters: the image starts as root by default, and only `node` can see the tmux session's socket).

### Why non-root user (`node`, UID/GID 1000 by default, remappable via PUID/PGID)?

Claude Code 2.x blocks `--dangerously-skip-permissions` when the process runs as root. Using a dedicated user solves this and is a security best practice. We reuse the `node` user already present in the base image to avoid GID conflicts, remapped to `PUID`/`PGID` at startup when those differ from the 1000/1000 default.

### Why `restart: unless-stopped` and not `always`?

`always` would restart the container even after an intentional `docker compose stop`, preventing maintenance. `unless-stopped` respects the operator's conscious decision to stop the container.

### Why `stdin_open: true` and `tty: true`?

Claude Code is a TUI (Text User Interface) application that requires:
- `stdin_open` (`-i`): interactive keyboard input
- `tty` (`-t`): a real terminal for interface rendering

Without these flags, the Claude interface does not render and the experience degrades. tmux also needs a TTY to manage its sessions properly.

### Why `/home/node/.claude` and not `/root/.claude`?

The container runs as the `node` user (non-root). This user's home is `/home/node/`, so Claude Code stores its configuration in `/home/node/.claude/`. This is consistent with the configured user (`ENV HOME=/home/node`) and necessary for `--dangerously-skip-permissions` to work correctly.

### Why does a fatal config error hold on `sleep infinity` instead of exiting?

A misconfigured `AUTO_START_MODE`, or a config/workspace directory the
`node` user can't write to (commonly because `CONFIG_BASE_PATH` was left
unset and silently fell back to a root-owned default), used to make
`entrypoint.sh` `exit 1`. Under `restart: unless-stopped`, that just
restarts the container immediately, over and over — `docker ps` shows
`Restarting`, and the terminal never holds still long enough to read why.
Instead, `entrypoint.sh` prints the exact problem and fix, then calls `exec
sleep infinity`, replacing itself with a process that does nothing but wait
for a signal. The container shows as `Up`, the error stays as the last
line in `docker logs`, and `docker stop`/`compose down` still work
normally since `sleep` terminates on `SIGTERM` by default.

### Why does `container_name:` default to the flat literal `claude-code-dock`, not something derived from `REMOTE_SESSION_NAME`?

Every host-side script (`status.sh`, `logs.sh`, `attach.sh`, `shell.sh`,
`claude.sh`, `remote.sh`) resolves its target container name via its own
flat `${CONTAINER_NAME:-claude-code-dock}` fallback, not Compose's
interpolation. `watchdog.sh` is the one exception: with no explicit name, it
auto-discovers every `claude-code-dock*` container instead of assuming a
single one (see CLAUDE.md's `scripts/watchdog.sh` entry for the full
behavior), since it's meant to keep watching every session on the host, not
just one. Changing only `docker-compose.yml`'s default
(Compose does support the nested `${VAR:-...${OTHER:-x}}` syntax that would
be needed) would silently orphan every already-running container created
under the old literal name and point the scripts at a name that doesn't
exist yet — a disruptive migration for existing installs. Instead,
`install.sh` and `new-session.sh` compensate by auto-writing
`CONTAINER_NAME=claude-code-dock-<session>` into the `.env`/`.env.<session>`
they generate, so the collision risk only surfaces for someone hand-editing
`.env` per project folder without setting this var themselves (`.env.example`
calls that out explicitly).

### Why do both `image:` and `build:` coexist in `docker-compose.yml`?

`image:` is what `docker compose pull` (the default install/update path)
fetches; `build:` is the fallback used when `CLAUDE_SOURCE_PATH` is set or
someone explicitly runs `docker compose build`. The registry/repo in
`image:` is a hardcoded literal, not a variable — only the tag is
configurable via `CLAUDE_DOCK_TAG` — since nobody running this project needs
to repoint it to a different fork's registry day to day, and
`CLAUDE_SOURCE_PATH` already covers local development.

Because both fields coexist, Compose only builds when the tag isn't already
present locally — a bare `docker compose up -d` will **not** rebuild an
already-tagged image, even with `CLAUDE_SOURCE_PATH` set. `install.sh` /
`update.sh` / `session-up.sh` handle this by building with `--no-cache`
explicitly, and by generating a gitignored `docker-compose.override.yml`
next to the base file whenever `CLAUDE_SOURCE_PATH` is set (removed again
when it's unset). That override sets `image: claude-code-dock:local` and
`pull_policy: build`; Compose auto-loads it for *any* `docker compose`
invocation run from the same directory — including a bare `docker compose
up -d` run by a tool that doesn't know this project's conventions, e.g.
Unraid's Compose Manager plugin — as long as one of those three scripts has
generated the override at least once.

This branching is deliberately **not** expressed as `${CLAUDE_SOURCE_PATH:-x}`
interpolation directly on `image:`/`pull_policy:` in the base file — it was
tried and reverted. Compose's substitution has no leak-free way to turn an
arbitrary host path into a fixed tag/policy value: the raw path commonly
contains `/`, which breaks a field that doesn't tolerate it. The generated
override file is the correct mechanism; see `docs/docker.md#local-development`.

---

## Security Model

```
+---------------------------------------------+
|              Boundaries                      |
|                                             |
|  Host filesystem                                |
|    +-- CONFIG_BASE_PATH/REMOTE_SESSION_NAME/    |
|        -------------------> /home/node/.claude  |
|         (credentials, mode 700)                 |
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
