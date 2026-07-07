# CLAUDE.md — claude-code-dock

This document is intended for AIs (like Claude Code itself), developers, and contributors who need to understand the project in depth. Read this file before making any modifications.

---

## Overview

claude-code-dock is a Docker infrastructure solution for running **Claude Code** (`@anthropic-ai/claude-code`) persistently on 24/7 servers — homelab, Unraid, NAS, Proxmox, VPS, or any always-on Linux machine.

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

**Primary goal, stated plainly:** let `claude` run as a durable, always-authenticated background process on a server you control, so a Remote Control session (or an SSH terminal) is available the instant you open it — no re-login, no re-preparing the environment, no dependency on a laptop staying awake.

---

## Usage Profiles

Every operator of this project falls into one of a small number of profiles, distinguished entirely by which optional `.env` variables they set. Everything below `REMOTE_SESSION_NAME`/`WORKSPACE_PATH`/`CONFIG_BASE_PATH` (required for any profile) is opt-in — nothing about GitHub, extra Claude arguments, PUID/PGID remapping, shared config, or the build source is ever mandatory. Use this section to figure out "which vars actually matter for what I'm trying to do" before touching `.env` or answering a user's question about it. The full per-variable reference stays in [Environment Variables](#environment-variables) below — this section is the "which subset of that table applies to me" index.

### Profile 1 — Default: simplest setup, no GitHub

Just wants Claude Code running persistently, reachable from a terminal (`AUTO_START_MODE=interactive`, the default), pointed at a local/NAS workspace. No git integration inside the container at all — the user commits/pushes from their own machine, or doesn't use git in this workspace.

- **Needs:** `REMOTE_SESSION_NAME`, `WORKSPACE_PATH`, `CONFIG_BASE_PATH`.
- **Leaves unset:** everything under `GIT_*`/`GITHUB_TOKEN_FILE`, `CLAUDE_SOURCE_PATH`, `PUID`/`PGID` (defaults to 1000/1000), `SHARED_CONFIG_PATH`.
- **Image source:** pulls the prebuilt image (registry/repo hardcoded in `docker-compose.yml`; `CLAUDE_DOCK_TAG` selects the tag, default `latest`) — no local build.
- **Enforced by:** `validate_config()` in `entrypoint.sh` only checks `AUTO_START_MODE` + writable config/workspace dirs; `check_env()` in `install.sh` hard-`fail`s only on missing `REMOTE_SESSION_NAME`/`WORKSPACE_PATH`/`CONFIG_BASE_PATH`. Nothing about git is ever validated for this profile because nothing about git is set.

### Profile 2 — Remote Control, no GitHub

Same as Profile 1, but wants access from any device via Claude Remote Control instead of (or in addition to) SSH+terminal.

- **Adds on top of Profile 1:** `AUTO_START_MODE=remote`.
- **Still leaves unset:** all `GIT_*`/`GITHUB_TOKEN_FILE` vars.
- Everything else (enforcement, image source) is identical to Profile 1.

### Profile 3 — Local or Remote + GitHub

Wants Claude to be able to commit and push from inside the container — either profile 1 or 2's execution mode, plus real git identity and (optionally) push/pull authentication.

- **Adds on top of Profile 1 or 2:** `GIT_USER_NAME`, `GIT_USER_EMAIL` (commit authorship only — no push capability by themselves), `GITHUB_TOKEN_FILE` (a **host path** to a token file, never the token itself — required for `git push`/pulling private repos), and optionally `GIT_REPO_URL` (HTTPS only, auto-clones into `/workspace` on first start if it's empty).
- **Enforced by:** nothing is `fatal()`/`fail`-blocking — all of these stay silently inert if unset (`entrypoint.sh` just skips the `git config --global` calls and the `GITHUB_TOKEN_FILE` mount falls back to a harmless `/dev/null`). This is why the [AI Guidelines below](#ai-guidelines--github-operations) exist: since nothing blocks a misconfigured attempt at the container level, the assistant has to check before acting instead of relying on a startup failure to catch it.
- See [Git & GitHub setup](README.md#git--github) for the host-side token-file steps.

### Profile 4 — claude-code-dock contributor / local build

Not just running the project — modifying claude-code-dock itself and needs the container built from a local working tree instead of the published image.

- **Adds:** `CLAUDE_SOURCE_PATH` (e.g. `.` or an absolute clone path) — highest priority of all build-source vars, always wins over `CLAUDE_DOCK_TAG`/`CLAUDE_DOCK_VERSION` when set.
- **Combines freely** with Profiles 1–3's other choices (execution mode, GitHub or not) — it only changes *where the image comes from*, not runtime behavior.
- **Enforced by:** `install.sh`/`update.sh` detect it and force `docker compose build --no-cache` automatically; a bare `docker compose up -d` run manually does *not* rebuild (see `docs/docker.md#local-development`) — this is a real footgun if scripts are bypassed, not a validation gap.
- See the [Contributor Guidelines](#contributor-guidelines) section below for the full PR workflow.

### Feature → requirement matrix

| Feature | Env var(s) that gate it | Enforced, or silent no-op when unset? |
|---------|--------------------------|----------------------------------------|
| Claude in terminal (interactive) | `AUTO_START_MODE=interactive` (default) | Validated (`validate_config()`) |
| Claude Remote Control | `AUTO_START_MODE=remote` | Validated (`validate_config()`) |
| Debug shell as PID 1 | `AUTO_START_MODE=shell` | Validated (`validate_config()`) |
| Git commit authorship | `GIT_USER_NAME`, `GIT_USER_EMAIL` | Silent no-op — commits just get no author identity |
| Git push / private-repo pull | `GITHUB_TOKEN_FILE` | Silent no-op — `git push`/private `git pull` just fails at git's own auth layer |
| Auto-clone into `/workspace` on first start | `GIT_REPO_URL` | Silent no-op; also skipped (not an error) if `/workspace` is already non-empty |
| `--dangerously-skip-permissions` | `CLAUDE_AUTO_APPROVE=true` | Applied via `settings.json`; defaults to `false` |
| Extra Claude CLI flags | `CLAUDE_EXTRA_ARGS` | Silent no-op when unset; malformed quoting warns and falls back to plain splitting |
| Remap container user off UID/GID 1000 | `PUID`/`PGID` | Validated — `0` or non-integer is `fatal()` |
| Shared `CLAUDE.md`/commands across sessions | `SHARED_CONFIG_PATH` | Silent no-op when unset |
| Build from local clone instead of pulling | `CLAUDE_SOURCE_PATH` | Not validated by the container itself; `install.sh`/`update.sh` enforce the correct build path, manual `docker compose up -d` does not |
| Pin the pulled image tag | `CLAUDE_DOCK_TAG` | Silent no-op when unset (falls back to `:latest`); ignored entirely if `CLAUDE_SOURCE_PATH` is set |
| Backup retention beyond the last 10 | `BACKUP_RETENTION` | Silent no-op when unset (defaults to 10) |
| Encrypted backups, non-interactive | `BACKUP_ENCRYPT_PASSPHRASE` (with `backup.sh --encrypt`) | Silent no-op when unset — `gpg` just prompts interactively instead |
| Watchdog restart notifications | `WATCHDOG_NTFY_URL` (host-side only) | Silent no-op when unset or `curl` missing |

---

## AI Guidelines — GitHub Operations

These rules apply whenever the user asks Claude Code to perform any GitHub or Git operation (push, pull, clone, commit, etc.).

### 1. Always verify Git configuration before acting

Before executing any GitHub-related task, verify that the following are actually usable:

| Variable | Required for |
|----------|-------------|
| `GIT_USER_NAME` | Commit authorship |
| `GIT_USER_EMAIL` | Commit authorship |
| `GITHUB_TOKEN_FILE` | Push, pull from private repos, any authenticated operation |
| `GIT_REPO_URL` | Auto-clone on startup |

**A literal `.env` file is not the only valid source and must not be treated as the source of truth.** `GIT_USER_NAME`, `GIT_USER_EMAIL`, and `GIT_REPO_URL` can just as validly arrive as real process environment variables — exported by the shell that ran `docker compose up`, injected via `environment:`/`env_file:` in `docker-compose.yml`, or passed with `docker run -e`. Checking only `test -f .env` / `grep .env` gives false negatives (see incident: a user had configured everything via process env vars with no `.env` file on disk at all; concluding "not configured" from the missing file alone was wrong).

**`GITHUB_TOKEN_FILE` is a special case — its env var presence is NOT a useful signal.** Inside the running container, `GITHUB_TOKEN_FILE` is always set to the fixed convention path `/run/secrets/github_token` (see `docker-compose.yml` and `docker/entrypoint.sh`), whether or not the operator actually configured a real token — `docker-compose.yml` mounts either the real host file there, or a harmless empty `/dev/null` when `.env`'s `GITHUB_TOKEN_FILE` is unset. So `[ -n "${GITHUB_TOKEN_FILE:-}" ]` is true either way and tells you nothing. Check the *effect* instead.

**Correct way to check — in this order, and only using presence tests, never printing values:**
1. Process environment, presence only, for the non-token vars: `[ -n "${GIT_USER_NAME:-}" ]`, `[ -n "${GIT_USER_EMAIL:-}" ]`, `[ -n "${GIT_REPO_URL:-}" ]`.
2. Effect already applied by `entrypoint.sh`, which is safe to print because it's not secret: `git config --global user.name`, `git config --global user.email`.
3. Whether a real token was actually mounted and non-empty, size only, never contents: `test -s /run/secrets/github_token` (a `test -f` alone isn't enough — the no-op `/dev/null` mount also passes `-f`-adjacent checks as a special file but is empty; `-s` requires actual bytes).
4. Whether the token was actually installed into git, existence only, never contents: `test -f ~/.git-credentials`.
5. Only if none of the above resolve it, fall back to checking `.env` on disk for `GIT_USER_NAME`/`GIT_USER_EMAIL`/`GIT_REPO_URL` — and even then, test for the key's presence, don't `cat`/print the file. For the token, check `grep -q '^GITHUB_TOKEN_FILE=.\+' .env` (presence of the *path* setting, not the secret itself).

**Never do any of the following, even just to "double-check" a value is set:**
- `cat /run/secrets/github_token`, `cat ~/.git-credentials`, or any command whose output could include the token itself.
- A shell one-liner that looks like it redacts a secret but doesn't in every branch. Example of the failure mode, generalized from a past incident with a different var: `` echo "${VAR:+<set, redacted>}${VAR:-<unset>}" `` — the second expansion (`:-`) still substitutes the *real value* whenever the variable is set and non-empty, because `:-` only falls back on unset/empty. If you need to show "is this set?", use a boolean test (`[ -n "$VAR" ] && echo set || echo unset`) and never interpolate the secret's own expansion into the string, redacted-looking or not.
- Piping/grepping a file that might contain the token (`.env`, `~/.git-credentials`, `/run/secrets/github_token`) through anything that echoes matched lines, unless the pattern only matches a variable *name*, not its value.

**If any required variable is missing or empty** (confirmed via the safe checks above), stop and inform the user. Do not proceed with the operation. Explain which variable is missing and how to configure it:

```
No GitHub token is mounted (checked: /run/secrets/github_token is empty, ~/.git-credentials absent).
Without it, git push/pull to GitHub will fail.

To configure it:
1. Go to https://github.com/settings/tokens → "Generate new token (classic)"
2. Name it (e.g. claude-code-dock), select scope "repo", generate and copy
3. Save it to a file ON THE HOST (not in .env), e.g.:
   echo -n "ghp_xxxxxxxxxxxxxxxxxxxx" > /srv/claude-secrets/github_token
   chmod 600 /srv/claude-secrets/github_token
4. Point .env at it: GITHUB_TOKEN_FILE=/srv/claude-secrets/github_token
5. Recreate the container: docker compose up -d --force-recreate
```

Apply the same pattern for `GIT_USER_NAME` and `GIT_USER_EMAIL`:

```
GIT_USER_NAME / GIT_USER_EMAIL are not set (checked: process environment, git config, .env).
Without them, git commits will have no author identity.

Set them either as environment variables for the container, or in your .env file:
   GIT_USER_NAME=Your Name
   GIT_USER_EMAIL=your@email.com

Then restart the container: docker compose restart
```

### 2. Always use HTTPS for push and pull

Never use SSH URLs (`git@github.com:...`) for remote operations. The container has no SSH keys configured.

Always use the HTTPS form:
```bash
# Correct
git remote set-url origin https://github.com/user/repo.git
git push
git pull

# Wrong — will fail
git remote set-url origin git@github.com:user/repo.git
```

If the current remote is SSH, switch it to HTTPS before proceeding:
```bash
git remote set-url origin https://github.com/USER/REPO.git
```

### 3. Checklist before any GitHub operation

Check via the safe methods in section 1 — process env presence test (for the non-token vars), `git config --global`, `test -s /run/secrets/github_token`, `test -f ~/.git-credentials` — not by printing or catting anything:

```
[ ] GIT_USER_NAME resolvable (env var or git config --global user.name)?
[ ] GIT_USER_EMAIL resolvable (env var or git config --global user.email)?
[ ] GitHub token present (test -s /run/secrets/github_token, or ~/.git-credentials exists) — required for push/pull?
[ ] Remote URL is HTTPS (not SSH)?
```

If any item is missing, inform the user and pause. Never silently skip a check or attempt to work around a missing credential. Never print or echo the value of the token (or any file that contains it) while performing this checklist.

### 4. Determine the GitHub profile once per session

The checklist in section 3 answers one underlying question: is this a GitHub-enabled setup ([Profile 3](#profile-3--local-or-remote--github)) or not ([Profile 1/2](#profile-1--default-simplest-setup-no-github))? Once answered in a conversation, treat it as settled for the rest of that conversation instead of re-running the full checklist on every subsequent commit/push/clone request:

- **Run the checklist once**, the first time a GitHub-flavored request comes up, and remember the result (configured / not configured, and which specific piece was missing if not) for the remainder of the conversation.
- **Re-check only when something could plausibly have changed the answer:** the user says they edited `.env`, rotated or added the token, changed git identity, or recreated/restarted the container since the last check — or the previous result was "missing X" and the user now says they fixed it.
- **Asymmetric risk, so don't cache blindly forever:** a stale "configured" result costs at most one failed git command that surfaces the real error anyway. A stale "not configured" result that never gets re-verified after the user says they fixed it just blocks them needlessly — always re-check on an explicit "I fixed it" / "try again" rather than repeating the old refusal from memory.
- **A clear user statement of their profile satisfies the check directly.** If the user has already said "no GitHub, just local" (or equivalent), don't contradict that by running file checks anyway — only fall back to the section 3 checklist when a GitHub-flavored request comes in *without* the user having stated their profile.
- This is in-conversation reasoning only, not a file or setting written anywhere — a new conversation always starts by running the checklist fresh on the first GitHub-flavored request.

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

2. **Reconnection via tmux:** PID 1 is tmux, which keeps the "main" session with Claude Code running. `docker exec -it claude-code-dock tmux attach-session -t main` connects to the session at any time, allowing multiple reconnections without restarting the process.

3. **No zombie processes:** When the parent process (PID 1) exits, all children exit. No risk of orphaned processes.

4. **Correct restart behavior:** The container stops when PID 1 stops, and `restart: unless-stopped` restarts it as needed.

### Non-root user (`node`, UID/GID `PUID`/`PGID`, default 1000/1000)

The **actual long-running process** (bash in shell mode, or the tmux session in interactive/remote mode) always runs as user `node`, **never root**. Reasons:

1. **Functional requirement:** Claude Code 2.x blocks `--dangerously-skip-permissions` when running as root (UID 0).
2. **Security best practice:** Containers should not run as root unnecessarily.
3. **Compatibility:** UID 1000 (the default) works with most NAS systems and Unraid; `PUID`/`PGID` let it be remapped to match a host user that isn't 1000.

The `node:lts-bookworm` base image already includes the `node` user (UID/GID 1000). We reuse it instead of creating a new one to avoid GID conflicts.

**How PUID/PGID remapping works:** the *image* itself has no permanent `USER` directive — it starts as root by default, on purpose, because `usermod`/`groupmod` (needed to remap `node` to a different UID/GID) require root. `entrypoint.sh`'s very first block (the "root step-down") checks `id -u`: if it's `0`, it optionally remaps `node` to `PUID`/`PGID` (default 1000/1000, a no-op when left at the default), `chown`s `$HOME` to match, then execs `setpriv --reuid=node --regid=node --init-groups` into a fresh invocation of itself — which is no longer root, so this block is skipped on that second pass and the rest of the script runs exactly as it always did. `setpriv` (util-linux, already present in the base image, no extra package) execve()s directly into the target rather than forking, so no wrapper process is left behind — PID 1 stays whatever ends up at the end of the exec chain (bash or the tmux session), preserving the PID 1 guarantee above. `PUID`/`PGID=0` is rejected with a `fatal()` — this project deliberately does not support running as root, remapped or not.

Because the image now starts as root, manual `docker exec` into the container (`scripts/attach.sh`, `shell.sh`, `claude.sh`, `remote.sh`) must explicitly pass `--user node` — otherwise `docker exec` defaults to root too, and root can't see the tmux session's socket (created by `node`, at a UID-specific path under `/tmp`) or write files as the right user. The Dockerfile `HEALTHCHECK` has the same problem and solves it the same way, wrapping its `tmux` calls in `setpriv --reuid=node --regid=node --init-groups`. `docker/claude-console.sh` (used by Unraid's Console feature, which may invoke it as root) steps down the same way before touching tmux.

### Volumes

```yaml
volumes:
  - ${WORKSPACE_PATH:-./workspaces}:/workspace
  - ${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}:/home/node/.claude
  - ${SHARED_CONFIG_PATH:-./shared-config}:/home/node/.claude-shared:ro
```

**Config volume (`CONFIG_BASE_PATH/REMOTE_SESSION_NAME → /home/node/.claude`):**
- Each session gets its own isolated subdirectory under `CONFIG_BASE_PATH`
- Claude Code stores credentials, settings, and cache in `~/.claude/`
- Without this volume, a new login would be required on every restart

**Shared config volume (`SHARED_CONFIG_PATH → /home/node/.claude-shared`, read-only):**
- Optional. Place `CLAUDE.md` and `commands/` here to share across all sessions
- The entrypoint merges `CLAUDE.md` and symlinks `commands/*.md` at startup
- Instance-specific instructions go in `CONFIG_BASE_PATH/<session>/CLAUDE-local.md`

**Workspace volume (`WORKSPACE_PATH → /workspace`):**
- Working directory where the user keeps their projects
- Flexible: can point to a Unraid array, NAS, local disk, etc.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | UID the container remaps its internal `node` account to before dropping root (see `docker/entrypoint.sh`'s root step-down block). `0` is rejected |
| `PGID` | `1000` | GID counterpart to `PUID` |
| `AUTO_START_MODE` | `interactive` | Execution mode: `interactive`, `remote`, `shell` |
| `CLAUDE_AUTO_APPROVE` | `false` | Enables `--dangerously-skip-permissions` (interactive/remote modes) |
| `CLAUDE_EXTRA_ARGS` | `` | Extra arguments appended to the final command. Parsed with quote-aware splitting (`eval`-based), so a quoted substring with spaces survives as one argument |
| `GITHUB_TOKEN_FILE` | `` | HOST path to a file holding the GitHub token — `docker-compose.yml` auto-mounts it read-only to the fixed in-container path `/run/secrets/github_token` |
| `CLAUDE_DOCK_TAG` | `latest` | Published tag `docker compose pull` fetches by default (`latest`, `stable`, or a pinned `vX.Y.Z`). Registry/repo are hardcoded in `docker-compose.yml`, not configurable |
| `CLAUDE_DOCK_VERSION` | `main` | Branch/tag to build from when not pulling the prebuilt image (build context ref) |
| `CLAUDE_SOURCE_PATH` | `` | Local claude-code-dock clone to use as build context instead of pulling/GitHub (advanced/dev use). Highest priority when set — always wins, `install.sh`/`update.sh` force `--no-cache` |
| `WORKSPACE_PATH` | `./workspaces` | Path to projects on the host |
| `CONFIG_BASE_PATH` | `./configs` | Base directory for per-session config subdirectories |
| `REMOTE_SESSION_NAME` | `` | **Required.** Unique session ID — isolates config, names backups, prevents duplicate containers |
| `SHARED_CONFIG_PATH` | `` | Optional shared dir with global `CLAUDE.md` and `commands/` applied to all sessions |
| `TZ` | `UTC` | Timezone |
| `GIT_USER_NAME` | `` | Name for git commits |
| `GIT_USER_EMAIL` | `` | Email for git commits |
| `BACKUP_RETENTION` | `10` | Number of backups to keep per session; oldest are removed automatically |
| `WATCHDOG_NTFY_URL` | `` | Host-side only (read by `scripts/watchdog.sh`, never passed into the container). Optional webhook URL notified on restart/restart-failure/fatal-marker-skip |

### Mode resolution

```
AUTO_START_MODE=remote      → remote mode
AUTO_START_MODE=shell       → shell mode
AUTO_START_MODE=interactive → interactive mode (default; also unset)
AUTO_START_MODE=<anything else> → fatal at startup (see validate_config in entrypoint.sh)
```

### Resulting commands per mode

```
interactive: claude [--dangerously-skip-permissions] [CLAUDE_EXTRA_ARGS]
remote:      claude [--dangerously-skip-permissions] --remote-control [REMOTE_SESSION_NAME] [CLAUDE_EXTRA_ARGS]
             (via docker/claude-remote-launch.sh — see below)
shell:       bash
```

Remote mode does not exec `claude` directly. `entrypoint.sh` hands the args above
to `docker/claude-remote-launch.sh`, which decides at runtime whether to add
`--continue`: it only tries it when this workspace already has a recorded
conversation (`~/.claude/projects/<encoded-cwd>/*.jsonl`), and if that attempt
fails within 15s (nothing actually resumable), it retries once without
`--continue` instead of leaving the tmux pane dead. A failure after running
longer than that is treated as a real crash and left to propagate, so Docker's
`restart: unless-stopped` handles it. See "File Responsibilities" below.

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
    ├─ Mounts volume: CONFIG_BASE_PATH/REMOTE_SESSION_NAME → /home/node/.claude
    ├─ Mounts volume: WORKSPACE_PATH → /workspace
    ├─ Mounts volume (optional, ro): SHARED_CONFIG_PATH → /home/node/.claude-shared
    └─ Starts container with ENTRYPOINT as root (see PUID/PGID below)
    │
    ▼
/usr/local/bin/entrypoint.sh runs (temporary PID 1, root)
    │
    ├─ Root step-down: id -u = 0, so remap 'node' to PUID/PGID (no-op at the
    │  1000/1000 default), chown $HOME, then exec setpriv --reuid=node
    │  --regid=node --init-groups into a fresh invocation of this same
    │  script — fatal() + sleep infinity if PUID/PGID are invalid or 0, or
    │  if the usermod/groupmod remap itself fails
    │  ↳ re-enters entrypoint.sh, this time as node (id -u ≠ 0, so this
    │    whole block is skipped) — everything below is unchanged from
    │    before PUID/PGID existed
    ├─ Displays claude-code-dock banner
    ├─ Displays environment variable configuration
    ├─ Validates: command -v claude (must exist) — fatal() + sleep infinity if missing
    ├─ Displays version: claude --version
    ├─ validate_config(): AUTO_START_MODE is interactive/remote/shell, and
    │  /home/node/.claude + /workspace are writable by the current PUID/PGID
    │  — fatal() holds PID 1 on sleep infinity instead of exiting on any
    │  failure here
    ├─ Configures Git: if GIT_USER_NAME and GIT_USER_EMAIL are set
    ├─ Persists skipDangerousModePermissionPrompt in settings.json
    ├─ Applies SHARED_CONFIG_PATH (CLAUDE.md merge + commands symlinks), if mounted
    ├─ Changes to: cd /workspace
    ├─ Determines mode: AUTO_START_MODE
    ├─ Builds CMD_ARGS with flags and CLAUDE_EXTRA_ARGS
    └─ Transfers control: exec tmux new-session -s main <CMD_BIN> [CMD_ARGS...]
    │                      (or exec bash in shell mode)
    ▼
tmux replaces entrypoint.sh as PID 1 (interactive/remote mode)
    │
    ▼
Container ready — connect via: docker exec -it --user node claude-code-dock tmux attach-session -t main
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
- `node` user (UID/GID 1000 by default, remappable via `PUID`/`PGID`): required for `--dangerously-skip-permissions` in Claude Code 2.x, which refuses to run as root.
- No permanent `USER` directive: the image starts as root by default, deliberately — `entrypoint.sh`'s root step-down block needs root to `usermod`/`groupmod` the `node` account to `PUID`/`PGID` before dropping to it via `setpriv`. See "Non-root user" under Architecture above.
- `setpriv` sanity check (`RUN command -v setpriv || exit 1`): util-linux's `setpriv` is what the step-down uses and is already part of every Debian base image — this just fails the build loudly if some future base image swap ever dropped it, instead of silently breaking the step-down at container startup.
- `WORKDIR /workspace`: default working directory.
- `ENV HOME=/home/node`: ensures the node user's home is used correctly.
- `VOLUME ["/home/node/.claude"]`: documents that this directory must be persisted.
- `HEALTHCHECK`'s tmux checks run via `setpriv --reuid=node --regid=node --init-groups tmux ...`: the healthcheck probe executes as the image's default user, now root, but the tmux session was created by `node` (whichever UID that currently maps to) — a root-invoked `tmux has-session` looks at root's own socket path and never finds it otherwise.
- `ENTRYPOINT`: ensures the entrypoint always executes.
- `/etc/claude-dock-build-source`: written at build time from the `CLAUDE_DOCK_SOURCE_PATH`/`CLAUDE_DOCK_VERSION` build args, as `local:<path>` or `github:<ref>`. Lets `entrypoint.sh` and `scripts/status.sh` report unambiguously which source produced the running image (mirrors the existing `/etc/claude-code-version` marker pattern).

**What NOT to do in the Dockerfile:**
- Do not add packages without clear justification
- Do not add a permanent `USER node` (or any other) directive — it would make `usermod`/`groupmod`-based `PUID`/`PGID` remapping impossible (they require root) without reintroducing some other runtime privilege escalation back to root, which is exactly what this pattern exists to avoid. The image starting as root is intentional; `entrypoint.sh`'s step-down block is what guarantees the actual long-running process still ends up non-root.
- Do not remove or bypass `entrypoint.sh`'s root step-down block, and do not add logic that runs as root beyond it — it's the only part of the script permitted to run as root, and only ever touches `$HOME` itself, never a bind mount
- Do not use `CMD` instead of `ENTRYPOINT`

---

### `docker-compose.yml`

**Responsibility:** Orchestrate the container with correct volumes, restart policy, and interactivity.

**Critical fields:**
- `stdin_open: true` and `tty: true`: required for Claude Code TUI
- `restart: unless-stopped`: automatic restart without blocking manual stops
- `container_name: ${CONTAINER_NAME:-claude-code-dock}`: name driven by `.env`; scripts depend on a stable, known name
- `image: ghcr.io/leonardomacedocano/claude-code-dock:${CLAUDE_DOCK_TAG:-latest}` + `build:`: both present intentionally — `image:` is what `docker compose pull` (the default install/update path) fetches; `build:` is the fallback path used when `CLAUDE_SOURCE_PATH` is set or someone explicitly runs `docker compose build`. The registry/repo in `image:` is a hardcoded literal (not a variable) — only the tag is configurable, via `CLAUDE_DOCK_TAG` (default `latest`; set `stable` or a pinned `vX.Y.Z`). There is deliberately no var to repoint the registry/repo itself — nobody running this project needs to pull from a different fork's registry day-to-day, and `CLAUDE_SOURCE_PATH` already covers the "I'm working on claude-code-dock itself" case. `build.args` also passes `CLAUDE_DOCK_SOURCE_PATH` (raw `CLAUDE_SOURCE_PATH`) and `CLAUDE_DOCK_VERSION` through so the Dockerfile can bake which one was used into `/etc/claude-dock-build-source` — read by `entrypoint.sh`'s startup log and `scripts/status.sh`.
- Because `image:` + `build:` coexist, Compose only builds when the tag isn't already present locally — a bare `docker compose up -d` will NOT rebuild an already-tagged image, even with `CLAUDE_SOURCE_PATH` set. `install.sh`/`update.sh` handle this correctly by explicitly calling `docker compose build --no-cache` whenever `CLAUDE_SOURCE_PATH` is set (never relying on `up -d` alone). Anyone bypassing the scripts must do the same: `docker compose build --no-cache && docker compose up -d`, or `docker compose up -d --build`. See `docs/docker.md#local-development`.
- `- ${GITHUB_TOKEN_FILE:-/dev/null}:/run/secrets/github_token:ro` in `volumes:`: the "optional file mount" idiom — mounts the real host token file when `.env`'s `GITHUB_TOKEN_FILE` is set, or a harmless empty `/dev/null` when it's not, so this line is always present and always safe regardless of whether the operator configured a token. Paired with `- GITHUB_TOKEN_FILE=/run/secrets/github_token` in `environment:`, which is a **literal**, not `${GITHUB_TOKEN_FILE:-}` — the container always looks at this fixed convention path; the host-side `.env` value is only ever used for the volume mount source, never passed into the container directly.
- `- PUID=${PUID:-1000}` / `- PGID=${PGID:-1000}` in `environment:`: read by `entrypoint.sh`'s root step-down block to remap the `node` account before dropping privilege. No corresponding `user:` field is set on the service — the container must start as root (the image's default, see the `Dockerfile` section) for that remap to be possible at all.

**What NOT to change without good reason:**
- Do not remove `stdin_open` or `tty` (breaks the interface)
- Do not change to `restart: always` (prevents manual maintenance)
- Do not change the `container_name` default or remove the `CONTAINER_NAME` variable (breaks all scripts when the variable is unset)
- Do not remove `image:` in favor of `build:`-only (breaks the pull-first fast path in `install.sh`/`update.sh`) or vice versa (breaks `CLAUDE_SOURCE_PATH`-based local dev)
- Do not make `CLAUDE_SOURCE_PATH` local builds rely on Docker's layer cache or on an image tag already being absent — always force `--no-cache` in scripts, since `CLAUDE_SOURCE_PATH` must deterministically win with zero cache dependency
- Do not change the `GITHUB_TOKEN_FILE` `environment:` line to interpolate `${GITHUB_TOKEN_FILE:-}` (the host value) instead of the literal `/run/secrets/github_token` — that would leak the *host path* into the container's env (harmless but pointless) and, worse, break `entrypoint.sh`'s assumption that this env var always points at the mount target
- Do not reintroduce a raw inline-secret env var for the GitHub token — the whole point of the file-mount design is that the token's value never sits in `.env`, in this file, or in the container's process environment

---

### `docker/entrypoint.sh`

**Responsibility:** Initialize the environment and transfer control to the correct process.

**Development rules:**
1. Must end with `exec tmux new-session -s main <LAUNCH_BIN> [CMD_ARGS...]` (or `exec bash` in shell mode). `LAUNCH_BIN` equals `CMD_BIN` (`claude`) in interactive mode; in remote mode it points to `docker/claude-remote-launch.sh` instead, so `--continue` retry logic can run before `claude` is actually exec'd. `CMD_ARGS` never contains `--continue` — that flag is decided at runtime by the wrapper, not built here.
2. Do not use `tail -f /dev/null` or infinite loops as a stand-in for real startup logic. The one sanctioned exception is `fatal()`'s `exec sleep infinity`: on an unrecoverable misconfiguration (invalid `AUTO_START_MODE`, unwritable config/workspace dir, missing `claude` binary), holding PID 1 there — instead of `exit 1` — keeps the container `Up` under `restart: unless-stopped` rather than restart-looping, so the error stays visible in `docker logs`. `sleep` still terminates immediately on `SIGTERM` (no trap installed), so `docker stop`/`compose down` behave normally.
3. Non-fatal validations stay non-destructive (warn but don't block); anything `fatal()` covers is intentionally blocking by design
4. Display useful messages to the user during initialization
5. Use `set -e` to fail fast on critical errors
6. Respect `AUTO_START_MODE` and `CLAUDE_EXTRA_ARGS`
7. New mandatory-config checks belong in `validate_config()`, called right after the `claude` binary check and before any mutation (symlinks, git config, settings.json) — fail via `fatal()`, not a bare `exit`
8. `fatal()`'s `sleep infinity` still makes the Dockerfile `HEALTHCHECK` report `unhealthy` (no tmux session was ever created), so `fatal()` touches `FATAL_MARKER_FILE` (default `/tmp/claude-dock-fatal`, overridable for tests) right before parking PID 1. `scripts/watchdog.sh` checks this marker via `docker exec` and skips restarting when it's present — otherwise an external watchdog reacting to that same `unhealthy` status would restart the container every cycle, recreating the exact loop `fatal()` exists to avoid. The marker is `rm -f`'d unconditionally at the top of the script on every run (including a plain `docker restart`, which re-execs this script but keeps the container's writable layer) so a stale marker from a past fatal run never survives into a run that didn't hit `fatal()` again.
9. The very first block in the file (before even the color variable definitions) is the root step-down: `if [ "$(id -u)" = "0" ]; then ... fi`. It validates `PUID`/`PGID` (rejecting `0` or non-integers via the same `fatal()`-style pattern — plain `echo`+marker+`sleep infinity`, since the real `fatal()` function isn't defined yet at this point in the file), optionally remaps `node` via `usermod`/`groupmod` when they differ from the 1000/1000 default, `chown`s `$HOME` (never a bind mount), then `exec setpriv --reuid=node --regid=node --init-groups /bin/bash "$0" "$@"` to re-run this same script as the now-non-root user — on that second pass `id -u` is no longer `0`, so this block is a no-op and everything below is unaffected. Do not move this block, and do not let anything above it (there is nothing above it on purpose) perform mutations — it's the only root-context code in the file.

**Required flow:**
```
root step-down (id -u = 0? remap node to PUID/PGID, chown $HOME, exec
setpriv into node → re-enter this script as node, skip this block this time)
→ banner → show config → validate claude → validate_config (mode + writable
config/workspace dirs; fatal() holds on sleep infinity instead of exiting)
→ configure git → settings.json → cd /workspace → determine mode
→ build CMD_ARGS → show info → exec tmux new-session -s main <LAUNCH_BIN> [CMD_ARGS...]
```

---

### `docker/claude-remote-launch.sh`

**Responsibility:** Decide, at container startup and only in remote mode, whether `claude --remote-control` should try `--continue` — and recover if that guess was wrong.

**Why this exists:** `claude --continue` hard-fails when the current workspace has no resumable conversation, with no built-in fallback. A brand-new `REMOTE_SESSION_NAME` always starts with an empty `~/.claude/projects/` — adding `--continue` unconditionally in `entrypoint.sh` killed the tmux pane on first boot for every new session name. See git history for the incident this fixed.

**Logic:**
1. Check whether `~/.claude/projects/<encoded-cwd>/*.jsonl` exists (`encoded-cwd` = `pwd` with `/` replaced by `-`, matching Claude Code's own project-dir naming).
2. If it does, run `claude "$@" --continue`. If that exits `0`, done.
3. If it exits non-zero within `FAST_FAIL_THRESHOLD` (15s) — treated as "nothing was actually resumable" — retry once without `--continue`.
4. If it exits non-zero after running longer than that, treat it as a real crash and propagate the exit code as-is (do not retry) so Docker's `restart: unless-stopped` handles it normally, instead of masking a genuine crash as a fresh, non-continued session.
5. If no history file exists at all, skip straight to `exec claude "$@"` — no wasted `--continue` attempt.

**Must not:**
- Use `set -e` (the script needs `claude`'s exit code after it fails, which errexit would prevent it from inspecting)
- Assume the presence of a `.jsonl` file guarantees `--continue` will succeed — it's a hint, checked defensively via the fast-fail retry, not a guarantee

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
4. `docker compose pull` (fetches the latest published image), falling back to `docker compose build --no-cache` if `CLAUDE_SOURCE_PATH` is set or the pull fails
5. `docker compose up -d`
6. Verify the container is running

**Why pull, not build, by default:** the published image is rebuilt in CI (weekly, and on every push to `main`) with a cache-busting build arg on the `npm install -g @anthropic-ai/claude-code` layer specifically, so it never serves a stale version from the GitHub Actions layer cache — see `.github/workflows/docker-publish.yml`. Pulling that image is faster than rebuilding locally and gets the same freshness guarantee. `--no-cache` remains necessary for the local-build fallback path, for the same cache-staleness reason.

**`:stable` tag (opt-in, manual only):** the weekly cron rebuild and every push to `main` always move `:latest` — by design, so it stays current with new `@anthropic-ai/claude-code` releases without anyone having to remember to update it. That also means `:latest` can, in principle, pick up a `claude` CLI release that breaks something, with no staging step. `docker-publish.yml`'s `workflow_dispatch` accepts a `promote_stable` boolean input (default `false`); when a maintainer runs the workflow manually with it checked, that specific build is additionally tagged and pushed as `:stable` (`type=raw,value=stable,enable=${{ github.event_name == 'workflow_dispatch' && inputs.promote_stable == true }}` in the `Extract metadata` step). `:stable` never moves on its own — only ever via that explicit manual action, after whoever runs it has actually tried the build. Users who want to avoid riding the weekly bump set `CLAUDE_DOCK_TAG=stable` in `.env` instead of the default `latest`.

---

### `scripts/backup.sh`

**Responsibility:** Create a backup of persisted configurations.

**What is backed up:**
- `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` (Claude Code credentials) — always included
- `./workspaces/` (local workspace) — included if not empty
- External workspace — only with `--include-workspace`

**Resolving `CONFIG_BASE_PATH`/`REMOTE_SESSION_NAME`/`WORKSPACE_PATH` (`load_env()`):** an already-exported process env var takes priority; `.env` on disk is only consulted for whatever isn't already set — same "`.env` is not the only valid source" principle as the GitHub-auth checks earlier in this file. Do not reintroduce an unconditional reset of these three to `""` before reading `.env` — that was a real bug: it silently discarded an already-exported value and fell back to the wrong (usually empty) `./configs/default`, backing up nothing while looking like it succeeded.

**Naming:** `claude-code-dock-backup-YYYY-MM-DD_HH-MM-SS.tar.gz`

**Retention:** Automatically keeps only the 10 most recent backups.

**`.env` masking (`backup_env()`):** two passes. First excludes any line whose *variable name* looks like a secret (`…TOKEN…`, `…KEY…`, `…SECRET…`, `…PASSWORD…`, `…PASSPHRASE…`, `…CREDENTIAL…`, `…AUTH…`, `…CERT…`). Second excludes any line whose *value* is a URL with credentials embedded (`user:pass@host` — e.g. someone setting `GIT_REPO_URL=https://user:ghp_xxx@github.com/...` instead of the recommended separate `GITHUB_TOKEN_FILE`), which the name-based pass alone would miss since `GIT_REPO_URL` doesn't look like a secret-named variable. This is a denylist, not an allowlist — best-effort, not a guarantee; a secret in an unrecognized variable name would slip through. Deliberately excludes `PAT`: it's a substring of `PATH`, and this project already has three load-bearing non-secret vars ending in exactly that suffix (`WORKSPACE_PATH`, `CONFIG_BASE_PATH`, `SHARED_CONFIG_PATH`) that adding it would silently strip from every backup.

**Encryption (`--encrypt`):** Pipes the finished `.tar.gz` through `gpg --symmetric --cipher-algo AES256`, producing a `.tar.gz.gpg` and removing the plaintext archive. Passphrase source, in order: `BACKUP_ENCRYPT_PASSPHRASE` env var (e.g. set in `.env`, non-interactive — for cron use) or an interactive `gpg` prompt if unset. Requires `gpg` on the host (not the container) since backups are host-side files.

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

**Uses `docker exec -it --user node ... tmux attach-session -t main`** to attach to the Claude Code session. `--user node` is required, not cosmetic: the image starts as root by default (see Architecture's "Non-root user" section), so a bare `docker exec` would default to root, which can't see the tmux session's socket (owned by `node`, at a UID-specific path under `/tmp`).

**Key distinction:**
- `./scripts/attach.sh` (tmux attach-session): connects to the running Claude Code session
- `./scripts/shell.sh` (docker exec bash): opens a separate bash process for debug/inspection

---

### `scripts/shell.sh`

**Responsibility:** Open a debug shell without interfering with the main process.

**Uses `docker exec -it --user node ... bash`** to open a separate bash process (distinct from the Claude tmux session), landing as `node` rather than the container's default root, matching this project's non-root-by-default posture for anything that touches the workspace/config.

---

### `scripts/claude.sh`

**Responsibility:** Run Claude Code in the container via `docker exec`.

**Uses `docker exec -it --user node ...`** — claude must never run as root (see Architecture's "Non-root user" section); without `--user node` this would default to the container's root user and either fail (Claude Code 2.x refuses `--dangerously-skip-permissions` as root) or create root-owned files in the workspace.

**Useful when:**
- The container is in `AUTO_START_MODE=shell` and the user wants to run claude manually
- The user wants a separate claude session from the main session
- The user wants to pass specific arguments to this session

---

### `scripts/remote.sh`

**Responsibility:** Run Claude Remote Control in the container via `docker exec`.

**Uses `docker exec -it --user node ...`** — same reasoning as `scripts/claude.sh` above: claude must never run as root.

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

### `scripts/watchdog.sh`

**Responsibility:** Restart a container that Docker has marked `unhealthy` per the Dockerfile `HEALTHCHECK` (tmux session missing/pane dead, or PID 1 not bash in shell mode).

**Why this exists:** `restart: unless-stopped` only reacts to the container *exiting* — Docker never auto-restarts a container that is still running but reports `unhealthy` (e.g. a wedged tmux pane where nothing has actually crashed). This script closes that gap by being run periodically from the *host* (cron), outside the container it's watching.

**Behavior:**
1. Reads `Health.Status` via `docker inspect --format '{{.State.Health.Status}}' <container>`.
2. If `unhealthy`, first checks `docker exec <container> test -f /tmp/claude-dock-fatal` — if that marker is present, `entrypoint.sh`'s `fatal()` is what parked PID 1, meaning this is a persistent misconfiguration (invalid `AUTO_START_MODE`, unwritable config/workspace dir), not a wedged process. A restart can't fix it, so the script warns and skips instead (exit 0 either way) — restarting anyway would just recreate the loop `fatal()` exists to avoid. Otherwise it runs `docker restart <container>` and logs it.
3. Any other status (`healthy`, `starting`, or no healthcheck configured) is a no-op.
4. Takes the container name as `$1`, defaulting to `${CONTAINER_NAME:-claude-code-dock}` from `.env` like the other scripts.

**Notifications (`notify()`, optional):** if `$WATCHDOG_NTFY_URL` is set (host-side env var or `.env`, never passed into the container), a plain-text `curl -d` POST is sent when the script actually restarts the container, when a restart fails, or when it skips due to the fatal marker. Works as-is with an ntfy.sh topic URL or any webhook accepting a raw POST body. Deliberately silent (no notification) on `healthy`/`starting`/no-healthcheck — those are the expected steady state on every cron tick, and notifying on those would just be noise at cron frequency. Never fails the watchdog run itself: a missing `curl` or an unreachable/erroring URL is swallowed (`|| true`) — a notification failing is not a reason to skip or fail the actual restart logic.

**Must not:**
- Restart on `starting` (still within `--start-period`) — only `unhealthy` triggers a restart
- Assume the container has a healthcheck at all — a missing one reports empty status, treated as a no-op, not an error
- Restart an `unhealthy` container that has the `/tmp/claude-dock-fatal` marker — see behavior #2 above
- Let a notification failure (missing `curl`, unreachable URL) affect the script's own exit code or skip the restart/skip logic

---

## Conventions

### Environment Variables

- `WORKSPACE_PATH`: path to the workspace on the host
- `CONFIG_BASE_PATH` / `REMOTE_SESSION_NAME`: base dir + session ID; credentials live at `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` on the host
- `AUTO_START_MODE`: execution mode (interactive/remote/shell) — validated at container startup by `validate_config()` in `entrypoint.sh`
- `CLAUDE_AUTO_APPROVE`: enables --dangerously-skip-permissions (default `false`)
- `CLAUDE_EXTRA_ARGS`: extra arguments for claude (quote-aware parsing)
- `TZ`: timezone
- `GIT_USER_NAME` / `GIT_USER_EMAIL`: optional Git configuration
- `GITHUB_TOKEN_FILE`: HOST path to a file with the GitHub PAT, auto-mounted read-only to `/run/secrets/github_token`

### File and Directory Naming

| Item | Convention |
|------|------------|
| Container | `claude-code-dock` (kebab-case) |
| Image | `claude-code-dock_claude-code-dock` (generated by compose) |
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

The correct solution is to persist the credentials that Claude Code itself saves after manual authentication. The user logs in once, and the `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` volume preserves those credentials.

### 2. Why non-root user (`node`, UID/GID 1000 by default, remappable via PUID/PGID)?

Claude Code 2.x blocks `--dangerously-skip-permissions` when running as root. Additionally, running as root in containers is a security anti-pattern. UID 1000 is compatible with most NAS systems and Unraid; `PUID`/`PGID` exist for the hosts where it isn't, so the container can match the host user instead of requiring a host-side `chown`.

### 3. Why bind mounts instead of named Docker volumes?

Bind mounts (`CONFIG_BASE_PATH/REMOTE_SESSION_NAME:/home/node/.claude`) have clear advantages:
- Direct visibility: the user can see files in that host directory
- Simple backup: `tar -czf backup.tar.gz <CONFIG_BASE_PATH>/<REMOTE_SESSION_NAME>/`
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

Allows customization without modifying the entrypoint. The user can add `--model`, `--verbose`, `--debug`, or any future Claude Code flag without needing a new version of claude-code-dock.

---

## Persistence

### Persistence Diagram

```
Host filesystem:
┌───────────────────────────────────────────────────────────┐
│  $CONFIG_BASE_PATH/$REMOTE_SESSION_NAME/  $WORKSPACE_PATH  │
│  ┌──────────────────┐         ┌──────────────────────┐    │
│  │ settings.json    │         │ my-project/          │    │
│  │ (credentials)    │         │ another-project/     │    │
│  └────────┬─────────┘         └──────────┬───────────┘    │
└───────────┼────────────────────────────┼──────────────────┘
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
  - CONFIG_BASE_PATH/REMOTE_SESSION_NAME/ is empty
  - User connects and logs in
  - Claude Code saves credentials to /home/node/.claude/
  - /home/node/.claude/ is CONFIG_BASE_PATH/REMOTE_SESSION_NAME/ (bind mount)
  - CONFIG_BASE_PATH/REMOTE_SESSION_NAME/ now has credentials

Container restarts:
  - CONFIG_BASE_PATH/REMOTE_SESSION_NAME/ still has credentials (they stayed on the host)
  - New container mounts it at /home/node/.claude/
  - Claude Code reads credentials → already authenticated
  - User does not need to log in again
```

---

## Login

### Manual Login Flow

Claude Code's login is **100% managed by the official Claude Code**. This project does not interfere with the process.

When the user connects for the first time:
1. `docker exec -it claude-code-dock tmux attach-session -t main` (or `./scripts/attach.sh`)
2. Claude Code detects the absence of credentials in `/home/node/.claude/`
3. Claude Code displays the authentication prompt
4. User follows the official authentication flow
5. Claude Code saves credentials to `/home/node/.claude/`
6. Since `/home/node/.claude/` is a bind mount of `CONFIG_BASE_PATH/REMOTE_SESSION_NAME/`, credentials stay on the host

---

## Security

### Project Security Principles

1. **No authentication interception:** The project does not read, modify, or intercept credentials.
2. **No login automation:** All authentication is performed by the user with Claude Code.
3. **No exposed ports:** The container does not listen on any network port.
4. **Isolated credentials:** `configs/` (and the legacy `config/`) excluded from git via `.gitignore`.
5. **Non-root user:** the actual long-running process (bash/tmux/claude) always runs as `node` (UID/GID 1000 by default, remappable via `PUID`/`PGID`) — the image starts as root only briefly, internally, to perform that remap before dropping privilege; see Architecture's "Non-root user" section.
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

1. **User node (UID 1000 by default) and volume permissions:** On some NAS or configurations, workspace files may belong to a different UID. Set `PUID`/`PGID` in `.env` to match that host UID/GID instead of chowning the host directory — `entrypoint.sh` remaps the container's `node` account to match at startup. (`chown -R <PUID>:<PGID> /your/workspace/` is still needed once, on the host, if the directory was already created with different ownership before PUID/PGID were set.)

2. **Remote Control as PID 1:** When `AUTO_START_MODE=remote`, Claude runs inside the tmux "main" session. Connect via `tmux attach-session -t main`. Primarily tested in interactive mode.

3. **Shell mode and restart policy:** With `AUTO_START_MODE=shell`, the container restarts after the user types `exit` from bash (restart: unless-stopped). This is expected behavior.

4. **CLAUDE_EXTRA_ARGS parsing:** The variable is parsed with quote-aware splitting (`eval`-based, see `docker/entrypoint.sh`), so a quoted substring survives as a single argument (e.g. `CLAUDE_EXTRA_ARGS=--append-system-prompt "be terse"`). Since it goes through `eval`, treat it like any other operator-controlled config value — it is not a place to interpolate untrusted input.

---

## Roadmap

### v1.0 (current)

- [x] Dockerfile with Claude Code (node user, non-root)
- [x] docker-compose.yml with persistent volumes
- [x] Three execution modes (interactive/remote/shell)
- [x] Management scripts (install, update, backup, restore, attach, shell, logs, claude, remote, status, watchdog, new-session, session-up, sessions)
- [x] AUTO_START_MODE, CLAUDE_AUTO_APPROVE, CLAUDE_EXTRA_ARGS, GITHUB_TOKEN_FILE variables
- [x] Complete documentation (Docker, Unraid, Troubleshooting, Security, Architecture)
- [x] Dockerfile `HEALTHCHECK` + `scripts/watchdog.sh` for external monitoring/auto-restart on `unhealthy`
- [x] `scripts/status.sh` — environment state overview
- [x] Community Applications template for Unraid (XML) — `unraid/claude-code-dock.xml`, not yet submitted upstream (see `docs/unraid.md#community-applications-template`)
- [x] GPG encryption support for backups (`scripts/backup.sh --encrypt`)
- [x] Configurable `PUID`/`PGID` (root step-down via `setpriv`, no more fixed UID 1000)
- [x] Optional watchdog notification hook (`WATCHDOG_NTFY_URL`)
- [x] Opt-in `:stable` image tag, promoted manually, independent of the weekly `:latest` rebuild

### Possible Future Improvements

**Infrastructure:**
- Multi-user support via separate instances
- Watchtower integration for automatic updates
- Submit the Unraid template to the Community Applications feed (needs a hosted 128x128 icon)

**Documentation:**
- Synology DSM guide with screenshots
- TrueNAS Scale guide
- Tailscale configuration examples

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
2. Set `CLAUDE_SOURCE_PATH=.` in `.env` so the build uses your local working tree, not GitHub — then test on a clean Docker build (`docker compose build --no-cache`)
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
