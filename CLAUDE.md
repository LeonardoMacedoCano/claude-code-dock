# CLAUDE.md — ClaudeDock

This document is intended for AIs (like Claude Code itself), developers, and contributors who need to understand the project in depth. Read this file before making any modifications.

---

## Overview

ClaudeDock is a Docker infrastructure solution for running **Claude Code** (`@anthropic-ai/claude-code`) persistently on 24/7 servers — homelab, Unraid, NAS, Proxmox, VPS, or any always-on Linux machine.

**What this project is:**
- A Dockerfile that packages Claude Code with its dependencies
- A docker-compose.yml that orchestrates the container with persistent volumes
- Management scripts (install, update, backup, restore, attach, shell, logs, claude, remote)
- Complete documentation for multiple platforms (Linux, Unraid, NAS)

**What this project is not:**
- A reimplementation or fork of Claude Code
- A web interface for Claude Code
- An authentication proxy or intermediary
- A login automation system
- A project focused on Remote Control (Remote Control is an optional feature)

---

## Goals

### Primary Goal

Allow Claude Code (`claude` CLI) to run persistently on 24/7 servers, preserving credentials, workspace, and configuration across restarts.

### Secondary Goals

1. **Zero configuration after initial setup:** After the first login, the user reconnects and finds the environment ready.
2. **Broad compatibility:** Linux, Unraid, Synology, QNAP, TrueNAS, ARM.
3. **Multiple execution modes:** interactive (default), remote, shell.
4. **User-friendly scripts:** Users without Docker experience should be able to install via `./scripts/install.sh`.
5. **Reasonable security:** Non-root user, protected credentials, no exposed ports.
6. **Maintainability:** Simple structure, no unnecessary dependencies.

---

## Architecture

### Process Pattern

The process selected by `AUTO_START_MODE` becomes **PID 1** of the container. This is the most important pattern in the project.

```
Container (interactive mode):
  PID 1: tmux (session "main" → /usr/local/bin/claude)
  (entrypoint.sh exited via exec tmux new-session)

Container (remote mode):
  PID 1: tmux (session "main" → /usr/local/bin/claude --remote-control)

Container (shell mode):
  PID 1: /bin/bash
```

### Why PID 1?

1. **Correct signals:** Docker sends `SIGTERM` to PID 1 to stop the container. The process receives the signal directly and can shut down gracefully.

2. **Reconnection via tmux:** PID 1 is tmux, which keeps the "main" session with Claude Code running. `docker exec -it claude-dock tmux attach-session -t main` connects to the session at any time, allowing multiple reconnections without restarting the process.

3. **No zombie processes:** When the parent process (PID 1) exits, all children exit. No risk of orphaned processes.

4. **Correct restart behavior:** The container stops when PID 1 stops, and `restart: unless-stopped` restarts it as needed.

### Non-root user (`node`, UID 1000)

The container runs as user `node` (UID/GID 1000), **not root**. Reasons:

1. **Functional requirement:** Claude Code 2.x blocks `--dangerously-skip-permissions` when running as root (UID 0).
2. **Security best practice:** Containers should not run as root unnecessarily.
3. **Compatibility:** UID 1000 works with most NAS systems and Unraid.

The `node:lts-bookworm` base image already includes the `node` user (UID/GID 1000). We reuse it instead of creating a new one to avoid GID conflicts.

### Volumes

```yaml
volumes:
  - ${WORKSPACE_PATH:-./workspaces}:/workspace
  - ${CONFIG_PATH:-./config}:/home/node/.claude
```

**Config volume (`CONFIG_PATH → /home/node/.claude`):**
- Claude Code stores credentials, settings, and cache in `~/.claude/` (resolves to `/home/node/.claude/` with USER node)
- Mounting as a volume ensures persistence across restarts
- Without this volume, a new login would be required on every restart

**Workspace volume (`WORKSPACE_PATH → /workspace`):**
- Working directory where the user keeps their projects
- Flexible: can point to a Unraid array, NAS, local disk, etc.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_START_MODE` | `interactive` | Execution mode: `interactive`, `remote`, `shell` |
| `CLAUDE_AUTO_APPROVE` | `true` | Enables `--dangerously-skip-permissions` (interactive mode) |
| `CLAUDE_EXTRA_ARGS` | `` | Extra arguments appended to the final command |
| `WORKSPACE_PATH` | `./workspaces` | Path to projects on the host |
| `CONFIG_PATH` | `./config` | Path to credentials on the host |
| `TZ` | `UTC` | Timezone |
| `GIT_USER_NAME` | `` | Name for git commits |
| `GIT_USER_EMAIL` | `` | Email for git commits |

### Mode resolution

```
AUTO_START_MODE=remote      → remote mode
AUTO_START_MODE=shell       → shell mode
AUTO_START_MODE=interactive → interactive mode (default)
```

### Resulting commands per mode

```
interactive: claude [--dangerously-skip-permissions] [CLAUDE_EXTRA_ARGS]
remote:      claude --remote-control [CLAUDE_EXTRA_ARGS]
shell:       bash
```

---

## Startup Flow

### Detailed Sequence

```
docker compose up -d
    │
    ▼
Docker Engine processes docker-compose.yml
    │
    ├─ Loads variables from .env
    ├─ Mounts volume: CONFIG_PATH → /home/node/.claude
    ├─ Mounts volume: WORKSPACE_PATH → /workspace
    └─ Starts container with ENTRYPOINT as user node
    │
    ▼
/usr/local/bin/entrypoint.sh runs (temporary PID 1, user node)
    │
    ├─ Displays ClaudeDock banner
    ├─ Displays environment variable configuration
    ├─ Validates: command -v claude (must exist)
    ├─ Displays version: claude --version
    ├─ Creates directories: mkdir -p /home/node/.claude /workspace
    ├─ Configures Git: if GIT_USER_NAME and GIT_USER_EMAIL are set
    ├─ Persists skipDangerousModePermissionPrompt in settings.json
    ├─ Validates /workspace: ls /workspace
    ├─ Changes to: cd /workspace
    ├─ Determines mode: AUTO_START_MODE
    ├─ Builds CMD_ARGS with flags and CLAUDE_EXTRA_ARGS
    └─ Transfers control: exec tmux new-session -s main <CMD_BIN> [CMD_ARGS...]
    │                      (or exec bash in shell mode)
    ▼
tmux replaces entrypoint.sh as PID 1 (interactive/remote mode)
    │
    ▼
Container ready — connect via: docker exec -it claude-dock tmux attach-session -t main
```

### Why `exec` and not a regular call?

```bash
# With exec — CORRECT:
exec tmux new-session -s main claude --dangerously-skip-permissions
# bash PID 1 → disappears → tmux PID 1 → claude (child of tmux)

# Without exec — INCORRECT:
tmux new-session -s main claude --dangerously-skip-permissions
# bash PID 1 → tmux PID 2 (child) → claude PID 3
# SIGTERM goes to bash, not to tmux/claude
```

---

## File Responsibilities

### `Dockerfile`

**Responsibility:** Build the image with all necessary dependencies.

**Technical decisions:**
- Base `node:lts-bookworm`: Node.js LTS is required for Claude Code. Debian Bookworm is stable.
- User `node` (UID 1000): required for `--dangerously-skip-permissions` in Claude Code 2.x.
- `WORKDIR /workspace`: default working directory.
- `ENV HOME=/home/node`: ensures the node user's home is used correctly.
- `VOLUME ["/home/node/.claude"]`: documents that this directory must be persisted.
- `ENTRYPOINT`: ensures the entrypoint always executes.

**What NOT to do in the Dockerfile:**
- Do not add packages without clear justification
- Do not switch back to root (`USER root`) after `USER node`
- Do not use `CMD` instead of `ENTRYPOINT`

---

### `docker-compose.yml`

**Responsibility:** Orchestrate the container with correct volumes, restart policy, and interactivity.

**Critical fields:**
- `stdin_open: true` and `tty: true`: required for Claude Code TUI
- `restart: unless-stopped`: automatic restart without blocking manual stops
- `container_name: claude-dock`: fixed name so scripts work correctly

**What NOT to change without good reason:**
- Do not remove `stdin_open` or `tty` (breaks the interface)
- Do not change to `restart: always` (prevents manual maintenance)
- Do not change `container_name` (breaks all scripts)

---

### `docker/entrypoint.sh`

**Responsibility:** Initialize the environment and transfer control to the correct process.

**Development rules:**
1. Must end with `exec tmux new-session -s main <CMD_BIN> [CMD_ARGS...]` (or `exec bash` in shell mode)
2. Do not use `tail -f /dev/null` or infinite loops
3. Validations must be non-destructive (warn but don't block, except for critical errors)
4. Display useful messages to the user during initialization
5. Use `set -e` to fail fast on critical errors
6. Respect `AUTO_START_MODE` and `CLAUDE_EXTRA_ARGS`

**Required flow:**
```
banner → show config → validate claude → create dirs → configure git
→ settings.json → validate workspace → cd /workspace → determine mode
→ build CMD_ARGS → show info → exec tmux new-session -s main <CMD_BIN> [CMD_ARGS...]
```

---

### `scripts/install.sh`

**Responsibility:** Complete onboarding for users without Docker experience.

**Must:**
- Validate Docker and Docker Compose before any action
- Create `.env` from `.env.example` if it doesn't exist
- Ask for confirmation before creating directories on the host
- Display clear instructions after installation

**Must not:**
- Modify system settings
- Install Docker automatically
- Perform destructive actions without confirmation

---

### `scripts/update.sh`

**Responsibility:** Update the Docker image safely.

**Required sequence:**
1. Check current status
2. Create backup (unless `--skip-backup`)
3. Stop the container
4. `docker compose build --no-cache` (ensures latest Claude Code version)
5. `docker compose up -d`
6. Verify the container is running

**Why `--no-cache`:** `npm install -g @anthropic-ai/claude-code` without cache always fetches the latest version. With cache, Docker may reuse an old layer with an outdated version.

---

### `scripts/backup.sh`

**Responsibility:** Create a backup of persisted configurations.

**What is backed up:**
- `./config/` (Claude Code credentials) — always included
- `./workspaces/` (local workspace) — included if not empty
- External workspace — only with `--include-workspace`

**Naming:** `claude-dock-backup-YYYY-MM-DD_HH-MM-SS.tar.gz`

**Retention:** Automatically keeps only the 10 most recent backups.

---

### `scripts/restore.sh`

**Responsibility:** Restore a backup safely.

**Safety rules:**
1. Always ask for confirmation before overwriting data
2. Always create a safety backup of current data before restoring
3. Stop the container before restoring
4. Restart the container after restoring

---

### `scripts/attach.sh`

**Responsibility:** Connect to the tmux session where Claude Code is running.

**Uses `docker exec -it ... tmux attach-session -t main`** to attach to the Claude Code session.

**Key distinction:**
- `./scripts/attach.sh` (tmux attach-session): connects to the running Claude Code session
- `./scripts/shell.sh` (docker exec bash): opens a separate bash process for debug/inspection

---

### `scripts/shell.sh`

**Responsibility:** Open a debug shell without interfering with the main process.

**Uses `docker exec -it ... bash`** to open a separate bash process (distinct from the Claude tmux session).

---

### `scripts/claude.sh`

**Responsibility:** Run Claude Code in the container via `docker exec`.

**Useful when:**
- The container is in `AUTO_START_MODE=shell` and the user wants to run claude manually
- The user wants a separate claude session from the main session
- The user wants to pass specific arguments to this session

---

### `scripts/remote.sh`

**Responsibility:** Run Claude Remote Control in the container via `docker exec`.

**Useful when:**
- The user wants a temporary Remote Control session without changing `AUTO_START_MODE`
- The container is in interactive mode and the user wants to test remote

**For Remote Control as the main process (PID 1):**
Set `AUTO_START_MODE=remote` in `.env`.

---

### `scripts/logs.sh`

**Responsibility:** View container logs.

**Supports:** `--tail N`, `--no-follow`, `--since DURATION`

---

## Conventions

### Environment Variables

- `WORKSPACE_PATH`: path to the workspace on the host
- `CONFIG_PATH`: path to credentials on the host
- `AUTO_START_MODE`: execution mode (interactive/remote/shell)
- `CLAUDE_AUTO_APPROVE`: enables --dangerously-skip-permissions
- `CLAUDE_EXTRA_ARGS`: extra arguments for claude
- `TZ`: timezone
- `GIT_USER_NAME` / `GIT_USER_EMAIL`: optional Git configuration

### File and Directory Naming

| Item | Convention |
|------|------------|
| Container | `claude-dock` (kebab-case) |
| Image | `claude-dock_claude-dock` (generated by compose) |
| Scripts | `snake_case.sh` |
| Directories | `kebab-case/` |
| Docs | `kebab-case.md` |

### Shell Scripts

- Use `#!/usr/bin/env bash`
- Use `set -euo pipefail` at the top (except entrypoint which uses `set -e`)
- Functions: `snake_case()`
- Environment variables: `UPPERCASE`
- Local variables: `UPPERCASE` (for consistency)
- Colors: define at the top of the script, use consistently
- Exit codes: 0 = success, 1 = generic error
- Error messages to `stderr` (`>&2`)
- No comments by default — only add one when the WHY is non-obvious

---

## Technical Decisions

### 1. Why not automate login?

Claude Code's login process is an official Anthropic authentication flow. Automating or intercepting it:
- Would violate Anthropic's Terms of Use
- Would introduce security risks
- Would create a dependency on internal behavior that may change
- Would be fundamentally unsustainable

The correct solution is to persist the credentials that Claude Code itself saves after manual authentication. The user logs in once, and the `CONFIG_PATH` volume preserves those credentials.

### 2. Why non-root user (`node`, UID 1000)?

Claude Code 2.x blocks `--dangerously-skip-permissions` when running as root. Additionally, running as root in containers is a security anti-pattern. UID 1000 is compatible with most NAS systems and Unraid.

### 3. Why bind mounts instead of named Docker volumes?

Bind mounts (`./config:/home/node/.claude`) have clear advantages:
- Direct visibility: the user can see files in `./config/`
- Simple backup: `tar -czf backup.tar.gz ./config/`
- Portability: moving the entire project preserves everything
- No special commands needed to access

### 4. Why `node:lts-bookworm` instead of `ubuntu` or `alpine`?

- **Node.js LTS included:** Claude Code is an npm package that requires Node.js.
- **Debian Bookworm:** More stable than Ubuntu for long-running containers. Alpine could have incompatibilities with native dependencies.
- **LTS:** Stable version with long-term support — important for a server running for months/years.
- **`node` user included:** The image already has UID 1000, no need to create it.

### 5. Why `restart: unless-stopped` and not `on-failure`?

- `on-failure`: restarts only on error exit. Claude Code may exit with code 0 (user typed /exit) and the container would not restart.
- `unless-stopped`: restarts on any exit, except when the operator stops it manually. Correct behavior for a persistent service.
- `always`: restarts even after an intentional `docker compose stop`, preventing maintenance.

### 6. Why three modes (interactive/remote/shell)?

- **interactive:** the main use case — Claude Code in the terminal.
- **remote:** for users who want Remote Control as the permanent main process.
- **shell:** for debugging and manual environment inspection.

Three well-defined modes are clearer than a combination of boolean flags.

### 7. Why `CLAUDE_EXTRA_ARGS`?

Allows customization without modifying the entrypoint. The user can add `--model`, `--verbose`, `--debug`, or any future Claude Code flag without needing a new version of ClaudeDock.

---

## Persistence

### Persistence Diagram

```
Host filesystem:
┌────────────────────────────────────────────────────────┐
│  ./config/                    $WORKSPACE_PATH           │
│  ┌──────────────────┐         ┌──────────────────────┐  │
│  │ settings.json    │         │ my-project/          │  │
│  │ (credentials)    │         │ another-project/     │  │
│  └────────┬─────────┘         └──────────┬───────────┘  │
└───────────┼────────────────────────────┼───────────────┘
            │ bind mount                  │ bind mount
            ▼                             ▼
Container filesystem (user node):
┌────────────────────────────────────────────────────────┐
│  /home/node/.claude/          /workspace/              │
│  ┌──────────────────┐         ┌──────────────────────┐  │
│  │ settings.json    │         │ my-project/          │  │
│  │ (credentials)    │         │ another-project/     │  │
│  └──────────────────┘         └──────────────────────┘  │
└────────────────────────────────────────────────────────┘
```

### Data Lifecycle

```
First use:
  - ./config/ is empty
  - User connects and logs in
  - Claude Code saves credentials to /home/node/.claude/
  - /home/node/.claude/ is ./config/ (bind mount)
  - ./config/ now has credentials

Container restarts:
  - ./config/ still has credentials (they stayed on the host)
  - New container mounts ./config/ at /home/node/.claude/
  - Claude Code reads credentials → already authenticated
  - User does not need to log in again
```

---

## Login

### Manual Login Flow

Claude Code's login is **100% managed by the official Claude Code**. This project does not interfere with the process.

When the user connects for the first time:
1. `docker exec -it claude-dock tmux attach-session -t main` (or `./scripts/attach.sh`)
2. Claude Code detects the absence of credentials in `/home/node/.claude/`
3. Claude Code displays the authentication prompt
4. User follows the official authentication flow
5. Claude Code saves credentials to `/home/node/.claude/`
6. Since `/home/node/.claude/` is a bind mount of `./config/`, credentials stay on the host

---

## Security

### Project Security Principles

1. **No authentication interception:** The project does not read, modify, or intercept credentials.
2. **No login automation:** All authentication is performed by the user with Claude Code.
3. **No exposed ports:** The container does not listen on any network port.
4. **Isolated credentials:** `./config/` excluded from git via `.gitignore`.
5. **Non-root user:** Container runs as `node` (UID 1000).
6. **Full transparency:** All code is open source and auditable.

### Attack Surface

```
What is exposed:
├── Terminal via tmux attach-session/exec (requires host access)
└── Filesystem via volumes (requires host access)

What is NOT exposed:
├── No network ports
├── No HTTP API
└── No network services
```

---

## Known Limitations

1. **User node (UID 1000) and volume permissions:** On some NAS or configurations, workspace files may belong to a different UID. Solution: `chown -R 1000:1000 /your/workspace/`.

2. **Remote Control as PID 1:** When `AUTO_START_MODE=remote`, Claude runs inside the tmux "main" session. Connect via `tmux attach-session -t main`. Primarily tested in interactive mode.

3. **Shell mode and restart policy:** With `AUTO_START_MODE=shell`, the container restarts after the user types `exit` from bash (restart: unless-stopped). This is expected behavior.

4. **CLAUDE_EXTRA_ARGS parsing:** The variable is read with `read -ra` (split by spaces). Arguments with internal spaces are not supported. Use only simple arguments.

---

## Roadmap

### v1.0 (current)

- [x] Dockerfile with Claude Code (node user, non-root)
- [x] docker-compose.yml with persistent volumes
- [x] Three execution modes (interactive/remote/shell)
- [x] Management scripts (install, update, backup, restore, attach, shell, logs, claude, remote)
- [x] AUTO_START_MODE, CLAUDE_AUTO_APPROVE, CLAUDE_EXTRA_ARGS variables
- [x] Complete documentation (Docker, Unraid, Troubleshooting, Security, Architecture)

### Possible Future Improvements

**Infrastructure:**
- Health check script for external monitoring
- Community Applications template for Unraid (XML)
- Multi-user support via separate instances
- Watchtower integration for automatic updates

**Documentation:**
- Synology DSM guide with screenshots
- TrueNAS Scale guide
- Tailscale configuration examples

**Scripts:**
- `scripts/status.sh` — environment state overview
- GPG encryption support for backups

---

## Contributor Guidelines

### Before modifying

1. Read this file completely
2. Understand the core principle: **the selected process is PID 1**
3. Read `docs/architecture.md` to understand the design
4. Never break the chain: `entrypoint.sh` must always end with `exec tmux new-session -s main <CMD_BIN> [CMD_ARGS...]` (or `exec bash` in shell mode)
5. Keep the container running as user `node` (non-root)

### When submitting a PR

1. Document the reason for the change
2. Test on a clean Docker build (`docker compose build --no-cache`)
3. Test all three modes: interactive, remote, shell
4. Verify that credentials persist after `docker compose restart`
5. Ensure scripts maintain `set -euo pipefail` and error handling
6. No comments by default — only add when the WHY is non-obvious

### Do not

- Add unnecessary dependencies to the image
- Automate authentication in any way
- Expose network ports without clear documented need
- Remove or alter `exec` in the entrypoint
- Modify Claude Code's login process
- Switch back to root user in the Dockerfile
