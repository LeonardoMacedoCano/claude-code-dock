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
- See [Git & GitHub Integration](docs/git-integration.md) for the host-side token-file steps.

### Profile 4 — claude-code-dock contributor / local build

Not just running the project — modifying claude-code-dock itself and needs the container built from a local working tree instead of the published image.

- **Adds:** `CLAUDE_SOURCE_PATH` (e.g. `.` or an absolute clone path) — highest priority of all build-source vars, always wins over `CLAUDE_DOCK_TAG`/`CLAUDE_DOCK_VERSION` when set.
- **Combines freely** with Profiles 1–3's other choices (execution mode, GitHub or not) — it only changes *where the image comes from*, not runtime behavior.
- **Enforced by:** `install.sh`/`update.sh`/`session-up.sh` detect it and (1) build with `--no-cache` directly, and (2) generate a `docker-compose.override.yml` next to `docker-compose.yml` that forces `pull_policy: build` and a dedicated local image tag. That file is Compose's own auto-loaded override — once it exists, even a bare `docker compose up -d` (run by anything, including tools that don't know this project's scripts, e.g. Unraid's Compose Manager plugin) rebuilds correctly, as long as it runs from the same directory. See `docs/docker.md#local-development`.
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
| Extra Claude CLI flags | `CLAUDE_EXTRA_ARGS` | Silent no-op when unset; malformed quoting warns and falls back to plain splitting; parsed via `xargs`, not `eval` — no shell expansion |
| Remap container user off UID/GID 1000 | `PUID`/`PGID` | Validated — `0` or non-integer is `fatal()` |
| Shared `CLAUDE.md`/commands across sessions | `SHARED_CONFIG_PATH` | Silent no-op when unset |
| Build from local clone instead of pulling | `CLAUDE_SOURCE_PATH` | Not validated by the container itself; `install.sh`/`update.sh`/`session-up.sh` generate `docker-compose.override.yml` to enforce it — a manual `docker compose up -d` run from the same directory picks that up too, once one of the scripts has generated it at least once |
| Pin the pulled image tag | `CLAUDE_DOCK_TAG` | Silent no-op when unset (falls back to `:latest`); ignored entirely if `CLAUDE_SOURCE_PATH` is set |
| Backup retention beyond the last 10 | `BACKUP_RETENTION` | Silent no-op when unset (defaults to 10) |
| Encrypted backups, non-interactive | `BACKUP_ENCRYPT_PASSPHRASE` (with `backup.sh --encrypt`) | Silent no-op when unset — `gpg` just prompts interactively instead |
| Scheduled daily backups | `install.sh --with-backup-cron` (flag, not an env var) | Opt-in host crontab entry; auto-adds `--encrypt` only if `BACKUP_ENCRYPT_PASSPHRASE` is already set in `.env` |
| CPU/memory resource limits | `docker-compose.resources.yml` (opt-in overlay, not an env var) | Not applied unless explicitly layered with `-f`; `install.sh` only warns when `CLAUDE_AUTO_APPROVE=true` and it's absent |
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

Full diagrams, component breakdown, and "why" for every design choice live in
[docs/architecture.md](docs/architecture.md) — read that file for the
complete picture. This section is the load-bearing summary an AI agent needs
before touching `Dockerfile`/`docker/entrypoint.sh`:

- **PID 1 is whatever `AUTO_START_MODE` selects** — `tmux` (hosting `claude`
  or `claude --remote-control` in a session named `main`) for
  `interactive`/`remote`, or plain `bash` for `shell`. This is the single
  most important invariant in the project: `entrypoint.sh` must always end
  with `exec tmux new-session -s main <LAUNCH_BIN> [CMD_ARGS...]` (or `exec
  bash`), never a plain call — see [File Responsibilities](#file-responsibilities)
  below for the exact rule.
- **The actual long-running process never runs as root.** The image itself
  starts as root by default (no permanent `USER` directive) specifically so
  `entrypoint.sh`'s root step-down block can `usermod`/`groupmod` the
  built-in `node` account to `PUID`/`PGID` (default 1000/1000, `0` rejected)
  before `exec setpriv --reuid=node --regid=node --init-groups`-ing into a
  fresh, now-non-root invocation of itself. `setpriv` execve()s directly
  (no fork), so no wrapper process survives to break the PID 1 guarantee
  above. Because the image starts as root, every manual `docker exec`
  (`scripts/attach.sh`/`shell.sh`/`claude.sh`/`remote.sh`, the Dockerfile
  `HEALTHCHECK`, `docker/claude-console.sh`) must pass `--user node`
  explicitly, or it lands as root and can't see the tmux socket `node`
  created.
- **Three volumes:** `WORKSPACE_PATH:/workspace`,
  `CONFIG_BASE_PATH/REMOTE_SESSION_NAME:/home/node/.claude` (per-session
  Claude Code credentials — without it, every restart needs a fresh login),
  and optionally `SHARED_CONFIG_PATH:/home/node/.claude-shared:ro` (global
  `CLAUDE.md`/`commands/` merged into every session at startup, with
  instance-specific overrides in `CONFIG_BASE_PATH/<session>/CLAUDE-local.md`).
  `SHARED_CONFIG_PATH` uses the same optional-file-mount idiom as
  `GITHUB_TOKEN_FILE` (falls back to `/dev/null` rather than a real host
  directory when unset) — see [`docker-compose.yml`](#docker-composeyml)
  below for why that matters.
- **`install.sh`/`new-session.sh` chown the host-side config/workspace
  directories to `PUID`/`PGID` before the container ever starts.** A brand-new
  `REMOTE_SESSION_NAME`'s config directory does not exist yet on first start;
  if something other than these scripts brings the container up first (a bare
  `docker compose up -d`, e.g. Unraid's Compose Manager plugin), Docker
  auto-creates that missing bind-mount source directory as `root:root`, and
  `entrypoint.sh`'s `validate_config()` correctly rejects it as unwritable —
  `docker logs` shows the boxed `fatal()` message with the exact fix, a
  one-time `chown -R <PUID>:<PGID> <path>` on the host.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PUID` | `1000` | UID the container remaps its internal `node` account to before dropping root (see `docker/entrypoint.sh`'s root step-down block). `0` is rejected |
| `PGID` | `1000` | GID counterpart to `PUID` |
| `AUTO_START_MODE` | `interactive` | Execution mode: `interactive`, `remote`, `shell` |
| `CLAUDE_AUTO_APPROVE` | `false` | Enables `--dangerously-skip-permissions` (interactive/remote modes) |
| `CLAUDE_EXTRA_ARGS` | `` | Extra arguments appended to the final command. Parsed with quote-aware splitting via `xargs` (not `eval`), so a quoted substring with spaces survives as one argument and shell metacharacters ($(...), backticks, globs) are never expanded |
| `GITHUB_TOKEN_FILE` | `` | HOST path to a file holding the GitHub token — `docker-compose.yml` auto-mounts it read-only to the fixed in-container path `/run/secrets/github_token` |
| `CLAUDE_DOCK_TAG` | `latest` | Published tag `docker compose pull` fetches by default (`latest`, `stable`, or a pinned `vX.Y.Z`). Registry/repo are hardcoded in `docker-compose.yml`, not configurable |
| `CLAUDE_DOCK_VERSION` | `main` | Branch/tag to build from when not pulling the prebuilt image (build context ref) |
| `CLAUDE_SOURCE_PATH` | `` | Local claude-code-dock clone to use as build context instead of pulling/GitHub (advanced/dev use). Highest priority when set — always wins; `install.sh`/`update.sh`/`session-up.sh` build with `--no-cache` and generate `docker-compose.override.yml` so it also wins for any later plain `docker compose up` |
| `WORKSPACE_PATH` | `./workspaces` | Path to projects on the host |
| `CONFIG_BASE_PATH` | `./configs` | Base directory for per-session config subdirectories |
| `REMOTE_SESSION_NAME` | `` | **Required.** Unique session ID — isolates config, names backups, prevents duplicate containers |
| `SHARED_CONFIG_PATH` | `` | Optional shared dir with global `CLAUDE.md` and `commands/` applied to all sessions. Unset falls back to `/dev/null` in `docker-compose.yml`'s mount (not a real host directory), so leaving this unset creates nothing on the host |
| `TZ` | `UTC` | Timezone |
| `GIT_USER_NAME` | `` | Name for git commits |
| `GIT_USER_EMAIL` | `` | Email for git commits |
| `BACKUP_RETENTION` | `10` | Number of backups to keep per session; oldest are removed automatically |
| `WATCHDOG_NTFY_URL` | `` | Read by `scripts/watchdog.sh` on the host for the `install.sh --with-watchdog` crontab path. Never passed into the main container. Optional webhook URL notified on restart/restart-failure/fatal-marker-skip |

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

Full step-by-step sequence diagram: [docs/architecture.md — Container
Startup](docs/architecture.md#container-startup). Order, in one line: root
step-down (see Architecture above) → banner/config display → `claude` binary
check → `validate_config()` (mode + writable config/workspace dirs, `fatal()`
on failure) → git config → `settings.json` → `SHARED_CONFIG_PATH` merge →
`cd /workspace` → build `CMD_ARGS` → `exec tmux new-session -s main
<LAUNCH_BIN> [CMD_ARGS...]` (or `exec bash` in shell mode). `entrypoint.sh`
must always end on that final `exec` — never a plain call, which would leave
`bash` (not `tmux`/`claude`) as PID 1 and misroute `SIGTERM`.

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
- `/etc/claude-dock-packages.list`: `dpkg -l` snapshotted into the image in the same layer as `apt-get upgrade`/`apt-get install`, third marker alongside the two above. Exists specifically because that `apt-get upgrade` (see the trade-off comment on that `RUN` line) makes the Debian package set non-reproducible across rebuilds of the same source — without this, there would be no way to tell after the fact which package versions a given running container actually has, making a regression introduced by a routine weekly rebuild unbisectable. Compare two images with `docker run --rm <image> cat /etc/claude-dock-packages.list` and `diff`.

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
- `container_name: ${CONTAINER_NAME:-claude-code-dock}`: name driven by `.env`; scripts depend on a stable, known name. The unset default is the flat literal `claude-code-dock`, **not** derived from `REMOTE_SESSION_NAME` — `install.sh` and `new-session.sh` both compensate by auto-writing `CONTAINER_NAME=claude-code-dock-<session>` into the `.env`/`.env.<session>` they generate, so the collision risk only surfaces for someone hand-editing `.env` per project folder (README's "Workflow A") who skips this var; `.env.example` calls that out explicitly. Deriving the default here from `REMOTE_SESSION_NAME` (Compose supports the nested `${VAR:-...${OTHER:-x}}` syntax already used below in `build.context`) was considered and rejected — every host-side script (`status.sh`, `logs.sh`, `attach.sh`, `shell.sh`, `claude.sh`, `remote.sh`, `watchdog.sh`) resolves its own target container name via a flat `${CONTAINER_NAME:-claude-code-dock}` fallback, not Compose's interpolation, so changing only this file's default would silently orphan every already-running container created under the old literal name and point the scripts at a name that doesn't exist yet — exactly the disruptive migration the bullet below warns against.
- `- CONTAINER_NAME=${CONTAINER_NAME:-claude-code-dock}` in `environment:`: informational only, mirrors the literal above so `entrypoint.sh`'s startup banner can print the actual `docker exec` command for this container instead of a hardcoded name that's wrong whenever `CONTAINER_NAME` is set to anything else.
- `image: ghcr.io/leonardomacedocano/claude-code-dock:${CLAUDE_DOCK_TAG:-latest}` + `build:`: both present intentionally — `image:` is what `docker compose pull` (the default install/update path) fetches; `build:` is the fallback path used when `CLAUDE_SOURCE_PATH` is set or someone explicitly runs `docker compose build`. The registry/repo in `image:` is a hardcoded literal (not a variable) — only the tag is configurable, via `CLAUDE_DOCK_TAG` (default `latest`; set `stable` or a pinned `vX.Y.Z`). There is deliberately no var to repoint the registry/repo itself — nobody running this project needs to pull from a different fork's registry day-to-day, and `CLAUDE_SOURCE_PATH` already covers the "I'm working on claude-code-dock itself" case. `build.args` also passes `CLAUDE_DOCK_SOURCE_PATH` (raw `CLAUDE_SOURCE_PATH`) and `CLAUDE_DOCK_VERSION` through so the Dockerfile can bake which one was used into `/etc/claude-dock-build-source` — read by `entrypoint.sh`'s startup log and `scripts/status.sh`.
- Because `image:` + `build:` coexist, Compose only builds when the tag isn't already present locally — a bare `docker compose up -d` will NOT rebuild an already-tagged image, even with `CLAUDE_SOURCE_PATH` set. `install.sh`/`update.sh`/`session-up.sh` handle this by explicitly building with `--no-cache` AND by generating `docker-compose.override.yml` (gitignored, next to `docker-compose.yml`) whenever `CLAUDE_SOURCE_PATH` is set — removed again when it's unset. That override sets `image: claude-code-dock:local` and `pull_policy: build` on the service; Compose auto-loads it for *any* `docker compose` invocation run from the same directory (not just these scripts), so a bare `docker compose up -d` — including one run by a tool that doesn't know this project's conventions, e.g. Unraid's Compose Manager plugin — also rebuilds correctly, as long as it runs from that same directory and one of the three scripts has generated the override at least once. This is deliberately not expressed as `${CLAUDE_SOURCE_PATH:-x}` interpolation directly on `image:`/`pull_policy:` in the base file — Compose's substitution has no leak-free way to turn an arbitrary host path into a fixed tag/policy value (the raw path, which commonly contains `/`, would end up concatenated into a field that doesn't tolerate it). See `docs/docker.md#local-development`.
- `- ${GITHUB_TOKEN_FILE:-/dev/null}:/run/secrets/github_token:ro` in `volumes:`: the "optional file mount" idiom — mounts the real host token file when `.env`'s `GITHUB_TOKEN_FILE` is set, or a harmless empty `/dev/null` when it's not, so this line is always present and always safe regardless of whether the operator configured a token. Paired with `- GITHUB_TOKEN_FILE=/run/secrets/github_token` in `environment:`, which is a **literal**, not `${GITHUB_TOKEN_FILE:-}` — the container always looks at this fixed convention path; the host-side `.env` value is only ever used for the volume mount source, never passed into the container directly.
- `- ${SHARED_CONFIG_PATH:-/dev/null}:/home/node/.claude-shared:ro` in `volumes:`: the same optional-file-mount idiom as `GITHUB_TOKEN_FILE` above, not the naive `${SHARED_CONFIG_PATH:-./shared-config}` this line used before — that earlier form fell back to a *real* host directory, which Docker auto-creates (root-owned) even when the operator never configured `SHARED_CONFIG_PATH` at all, leaving an unexplained artifact on the host for a feature nobody opted into. `entrypoint.sh` only ever does `[ -f "$SHARED_DIR"/CLAUDE.md ]` / `[ -d "$SHARED_DIR"/commands ]` against this path, both of which simply evaluate false when the mount target is `/dev/null` instead of a real directory, so this degrades to the same silent no-op as leaving the feature unmounted entirely — same reasoning as [Usage Profiles](#usage-profiles)'s feature matrix above.
- Resource limits (CPU/memory) are **not** in this file. They live in the opt-in `docker-compose.resources.yml` overlay (not auto-loaded by Compose — explicit `-f` required) instead of a commented-out block here, for two reasons: (1) `docker-compose.override.yml` is already scripts-managed for `CLAUDE_SOURCE_PATH` (see `sync_override_file()` below) and would silently clobber anything else placed in it; (2) a hardcoded limit in this tracked file would be wrong for most hosts. See that file's own header comment and `scripts/install.sh`'s `check_auto_approve_safety()`, which warns when `CLAUDE_AUTO_APPROVE=true` and `docker-compose.resources.yml` isn't present on disk.
- `- PUID=${PUID:-1000}` / `- PGID=${PGID:-1000}` in `environment:`: read by `entrypoint.sh`'s root step-down block to remap the `node` account before dropping privilege. No corresponding `user:` field is set on the service — the container must start as root (the image's default, see the `Dockerfile` section) for that remap to be possible at all.

**What NOT to change without good reason:**
- Do not remove `stdin_open` or `tty` (breaks the interface)
- Do not change to `restart: always` (prevents manual maintenance)
- Do not change the `container_name` default or remove the `CONTAINER_NAME` variable (breaks all scripts when the variable is unset)
- Do not remove `image:` in favor of `build:`-only (breaks the pull-first fast path in `install.sh`/`update.sh`) or vice versa (breaks `CLAUDE_SOURCE_PATH`-based local dev)
- Do not make `CLAUDE_SOURCE_PATH` local builds rely on Docker's layer cache or on an image tag already being absent — always force `--no-cache` in scripts, since `CLAUDE_SOURCE_PATH` must deterministically win with zero cache dependency
- Do not move the `CLAUDE_SOURCE_PATH` branching into `docker-compose.yml` itself via `${CLAUDE_SOURCE_PATH:-x}` interpolation on `image:`/`pull_policy:` — this was tried and reverted; the raw path leaks into those fields (breaks on `/`) since Compose's substitution can't express a leak-free two-way branch from one arbitrary-content variable. The `docker-compose.override.yml` generated by the scripts is the correct mechanism; keep it as a separate, gitignored file
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
- If `CLAUDE_AUTO_APPROVE=true` and `docker-compose.resources.yml` is not present on
  disk, require an explicit y/N confirmation before continuing
  (`check_auto_approve_safety()`) — with no per-command checkpoint and no CPU/memory
  ceiling, nothing else bounds what a single Claude-issued command can do to this
  host. `docker/entrypoint.sh` logs the same warning on every start so it's still
  visible when the container was brought up some other way (bare `docker compose up`,
  `scripts/update.sh`, `scripts/session-up.sh`, a third-party tool). Detection is
  best-effort (file presence, not "will this exact `docker compose up` load it") —
  see the `docker-compose.yml` section above.
- `--with-watchdog`: after a successful install, add a host crontab entry running
  `scripts/watchdog.sh` every 5 minutes (`setup_watchdog_cron()`), idempotently —
  re-running it must never duplicate the cron line. Falls back to printing the line
  to schedule manually when `crontab` isn't available on this host.
- `--with-backup-cron`: same mechanism as `--with-watchdog` (`setup_backup_cron()`),
  a daily-at-03:00 host crontab entry running `scripts/backup.sh --quiet`, idempotent
  the same way. Automatically appends `--encrypt` to the cron line when
  `BACKUP_ENCRYPT_PASSPHRASE` is already set in `.env` (read via `check_env()`'s
  earlier `source .env`) — without a passphrase, `gpg` would otherwise block a cron
  job forever waiting on an interactive prompt with no terminal attached, so
  `--encrypt` is deliberately NOT added when unset.

**Must not:**
- Modify system settings
- Install Docker automatically
- Perform destructive actions without confirmation

---

### `scripts/update.sh`

**Responsibility:** Update the Docker image safely.

**Required sequence:**
1. Check current status, and record the container's current image ID + resolved image ref (`OLD_IMAGE_ID`/`OLD_IMAGE_REF`, via `docker inspect`) before touching anything — the only chance to capture this is before the pull/rebuild below replaces it
2. Create backup (unless `--skip-backup`)
3. Stop the container
4. `docker compose pull` (fetches the latest published image), falling back to `docker compose build --no-cache` if `CLAUDE_SOURCE_PATH` is set or the pull fails
5. `docker compose up -d`
6. Wait for `Running`, then wait for Docker's own `HEALTHCHECK` to report `healthy` (`wait_for_healthy()`) — not just that the process didn't immediately exit
7. If it never reaches `Running`, or goes `unhealthy`/times out waiting to: `attempt_rollback()` re-`docker tag`s `OLD_IMAGE_ID` back onto `OLD_IMAGE_REF` (still on disk — `cleanup_old_images`'s `docker image prune` runs later, specifically after this, so the previous image is never garbage-collected before a rollback might need it) and recreates with `--force-recreate`. Exits non-zero either way (rollback succeeded or not) — a rolled-back-to-working-state result is still a failed *update*, and must not be reported as success

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

**Unencrypted-credentials warning:** `print_result()` tracks whether the archive included `CONFIG_DIR` (`BACKUP_HAS_CONFIG`, set in `create_backup_archive()`) and, when it did and `--encrypt` wasn't passed, prints an explicit note that the `.tar.gz` contains plaintext Claude Code session credentials — since the default (no flag) path produces exactly that file, silently.

**Scheduling:** this script never schedules itself — it only runs when invoked manually or by whatever calls it. `scripts/install.sh --with-backup-cron` is the supported way to run it automatically (a daily host crontab entry); see that script's section above. Not wiring this up at all is a real gap for a project whose primary asset (Claude Code session credentials) lives nowhere else — treat losing the config volume with no backup as the actual failure mode `--with-backup-cron` exists to prevent, not `scripts/watchdog.sh`'s wedged-pane scenario, which is merely inconvenient by comparison.

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

**Uses `docker exec -it --user node ... tmux attach-session -t main`** to attach to the Claude Code session. `--user node` is required, not cosmetic: the image starts as root by default (see Architecture above), so a bare `docker exec` would default to root, which can't see the tmux session's socket (owned by `node`, at a UID-specific path under `/tmp`).

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

**Uses `docker exec -it --user node ...`** — claude must never run as root (see Architecture above); without `--user node` this would default to the container's root user and either fail (Claude Code 2.x refuses `--dangerously-skip-permissions` as root) or create root-owned files in the workspace.

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

**Scheduling** (this script alone doesn't self-schedule): `./scripts/install.sh --with-watchdog` adds a host crontab entry, every 5 minutes — no extra container, no elevated Docker access beyond what running `docker` commands already implies.

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

Claude Code 2.x blocks `--dangerously-skip-permissions` when running as root, and running as root in containers is a security anti-pattern besides. Full mechanism (root step-down, `setpriv`, `PUID`/`PGID`): [Architecture](#architecture) above and [docs/architecture.md](docs/architecture.md).

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

### 5. Why `restart: unless-stopped` and not `on-failure`/`always`?

`on-failure` misses a clean `/exit` (code 0); `always` fights manual
maintenance by restarting even after `docker compose stop`. Full comparison:
[docs/architecture.md — Design Decisions](docs/architecture.md#design-decisions).

### 6. Why three modes (interactive/remote/shell)?

- **interactive:** the main use case — Claude Code in the terminal.
- **remote:** for users who want Remote Control as the permanent main process.
- **shell:** for debugging and manual environment inspection.

Three well-defined modes are clearer than a combination of boolean flags.

### 7. Why `CLAUDE_EXTRA_ARGS`?

Allows customization without modifying the entrypoint. The user can add `--model`, `--verbose`, `--debug`, or any future Claude Code flag without needing a new version of claude-code-dock.

---

## Persistence & Login

Bind mounts, not named volumes (see [Technical Decisions](#technical-decisions)
above for why) — `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` on the host *is*
`/home/node/.claude` in the container, so whatever Claude Code writes there
(credentials, `settings.json`, session history) survives container restarts
with no extra sync step. Full diagram: [docs/architecture.md — Data
Flow](docs/architecture.md#data-flow).

Login is **100% handled by the official `claude` CLI** — this project never
reads, intercepts, or automates it (see [Technical Decisions
#1](#technical-decisions)). First connection
(`./scripts/attach.sh` or `docker exec -it --user node <container> tmux
attach-session -t main`): Claude Code finds no credentials in
`/home/node/.claude/`, prompts for the official auth flow, then saves them
there — which, being the bind mount above, persists them on the host for
every future restart with no re-login.

---

## Security

Full threat model, checklist, and credential-protection details:
[docs/security.md](docs/security.md) — read that file, not just this
summary, before any change that touches credentials, tokens, or the
container's privilege boundary. In one line: no port ever exposed, no
authentication interception, non-root long-running process (see
Architecture above), no host-level privilege needed at all.

---

## Known Limitations

1. **User node (UID 1000 by default) and volume permissions:** On some NAS or configurations, workspace files may belong to a different UID. Set `PUID`/`PGID` in `.env` to match that host UID/GID instead of chowning the host directory — `entrypoint.sh` remaps the container's `node` account to match at startup. (`chown -R <PUID>:<PGID> /your/workspace/` is still needed once, on the host, if the directory was already created with different ownership before PUID/PGID were set.)

2. **Remote Control as PID 1:** When `AUTO_START_MODE=remote`, Claude runs inside the tmux "main" session. Connect via `tmux attach-session -t main`. Primarily tested in interactive mode.

3. **Shell mode and restart policy:** With `AUTO_START_MODE=shell`, the container restarts after the user types `exit` from bash (restart: unless-stopped). This is expected behavior.

4. **CLAUDE_EXTRA_ARGS parsing:** The variable is parsed with quote-aware splitting via `xargs -n1` (see `docker/entrypoint.sh`), so a quoted substring survives as a single argument (e.g. `CLAUDE_EXTRA_ARGS=--append-system-prompt "be terse"`). Unlike the earlier `eval`-based implementation, `xargs` never expands `$(...)`, backticks, `~`, or globs — a value containing shell metacharacters is only ever passed through as literal text, never executed. A non-zero `xargs` exit (unmatched quote) falls back to plain whitespace splitting with a warning rather than aborting startup.

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
- [x] CI smoke test (`tests/smoke.sh`): builds the image and boots a real container per `AUTO_START_MODE`, gating `docker-publish.yml`'s publish job on Docker's own `HEALTHCHECK` actually going `healthy` — the mocked `bats` suite alone never exercised a real container
- [x] `scripts/install.sh --with-watchdog`: one-flag host crontab setup for `scripts/watchdog.sh`, idempotent
- [x] `CLAUDE_AUTO_APPROVE=true` without resource limits now requires explicit confirmation in `install.sh`, and is logged as a warning by `entrypoint.sh` on every start regardless of how the container was brought up
- [x] `scripts/backup.sh` warns explicitly when an unencrypted archive contains plaintext credentials
- [x] `scripts/install.sh --with-backup-cron`: one-flag daily host crontab setup for `scripts/backup.sh`, idempotent, auto-encrypting when `BACKUP_ENCRYPT_PASSPHRASE` is already configured
- [x] `docker-compose.resources.yml`: opt-in CPU/memory limit overlay (explicit `-f`, never auto-loaded), replacing the commented-out `deploy:` block that used to live in `docker-compose.yml` itself
- [x] `SHARED_CONFIG_PATH` mount now falls back to `/dev/null` (like `GITHUB_TOKEN_FILE`) instead of a real host directory when unset — no more unexplained `./shared-config/` created for a feature nobody opted into
- [x] `/etc/claude-dock-packages.list`: `dpkg -l` snapshot baked into the image, so an unpinned `apt-get upgrade` build is bisectable after the fact
- [x] `scripts/status.sh --json`: machine-readable output for homelab dashboard integration (Homepage, Uptime Kuma, Grafana, ...)
- [x] Startup timing + an explicit "ACTION REQUIRED" log block in `entrypoint.sh`/`docker/claude-remote-launch.sh`, persisted to `dock.log`: says which step startup is on, how long each step took, and — when a manual login or remote-control pairing is still pending — the exact `docker exec` command to run, since `docker logs` stops showing readable text the moment `tmux` takes over the tty
- [x] `scripts/session-up.sh` now runs the same `CLAUDE_AUTO_APPROVE` safety confirmation `install.sh` already had
- [x] CI validates `docker-compose.yml` (`docker compose config`, all overlays) and `tests/smoke.sh` now also boots via a real `docker compose up` and runs an end-to-end disaster-recovery drill through the real `backup.sh`/`restore.sh`
- [x] `scripts/update.sh` waits for `healthy` (not just `Running`) after updating and automatically rolls back to the previous image if it isn't, instead of leaving a broken container up
- [x] `CHANGELOG.md`: dated, user-facing log of what changed, linked from the README

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
