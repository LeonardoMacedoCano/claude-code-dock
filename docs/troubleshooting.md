# Troubleshooting Guide — claude-code-dock

For architecture details, see [Architecture](architecture.md). For Docker commands reference, see [Docker Reference](docker.md).

## Quick Diagnosis

Before any specific troubleshooting, collect this information:

```bash
# Container status
docker ps -a --filter name=claude-code-dock

# Last 50 lines of logs
docker logs --tail 50 claude-code-dock

# Docker version
docker --version
docker compose version

# Resource usage
docker stats claude-code-dock --no-stream

# Container system info
docker exec claude-code-dock uname -a
docker exec claude-code-dock node --version
docker exec claude-code-dock claude --version
docker exec claude-code-dock whoami  # should show 'node'
```

---

## Startup Problems

### Container does not start — "Exited (1)"

**Symptom:**
```
claude-code-dock   Exited (1) 2 seconds ago
```

**Diagnosis:**
```bash
docker logs claude-code-dock
```

**Causes and solutions:**

**A) Permission error on the config volume:**

The entrypoint validates this on every start and now fails with a boxed,
explicit message instead of a bare `EACCES` — look for `✗ FATAL: Config
directory is not writable` in the logs. Fix:
```bash
# Fix permissions (UID 1000 = node user, or your PUID/PGID if set in .env)
# on CONFIG_BASE_PATH/REMOTE_SESSION_NAME
chown -R 1000:1000 <your CONFIG_BASE_PATH>/<REMOTE_SESSION_NAME>
```
Also confirm `CONFIG_BASE_PATH` is actually set in `.env` — if empty, it
silently falls back to `./configs` (relative to wherever `docker compose`
runs from), which Docker then creates owned by root.

**Alternative — if the directory is already owned by a host user that isn't
UID/GID 1000** (common on some NAS setups): instead of chowning the host
directory to 1000, set `PUID`/`PGID` in `.env` to that host user's `id -u`/
`id -g` and restart. The container remaps its internal `node` account to
match instead of requiring the host directory to change ownership.

**B) WORKSPACE_PATH does not exist:**
```
Error response from daemon: invalid mount config for type "bind": bind source path does not exist
```
```bash
# Create the directory on the host
mkdir -p /your/workspace/path
```

**C) Image was not pulled/built yet:**
```
Unable to find image 'ghcr.io/leonardomacedocano/claude-code-dock:latest' locally
```
```bash
docker compose pull
# or, if CLAUDE_SOURCE_PATH is set:
docker compose build
```

---

### Container starts but stops immediately

**Diagnosis:**
```bash
# View exit code
docker inspect claude-code-dock | jq '.[0].State'

# View full logs
docker logs claude-code-dock
```

**Cause A — Claude Code not found in the image:**
```
✗ FATAL: Claude Code binary missing
```
```bash
# Re-pull the image (or rebuild without cache if CLAUDE_SOURCE_PATH is set)
docker compose pull
docker compose up -d
```

**Cause B — Entrypoint permission problem:**
```bash
# Check entrypoint permissions (use your local image name here if you built
# with CLAUDE_SOURCE_PATH instead of pulling)
docker run --rm --entrypoint ls \
  ghcr.io/leonardomacedocano/claude-code-dock:latest \
  -la /usr/local/bin/entrypoint.sh

# If needed, re-pull (or rebuild without cache if building locally)
docker compose pull
```

---

### Container restart loop

**Symptom:**
```
NAME          STATUS
claude-code-dock   Restarting (1) 3 seconds ago
```

The entrypoint validates configuration (execution mode, and that the config
and workspace directories are actually writable by UID 1000) before doing
anything else. On a fatal problem it now prints a boxed `✗ FATAL: ...`
message naming the exact cause and the fix, then holds PID 1 on `sleep
infinity` instead of exiting — so the container shows as `Up` (not
`Restarting`) and the message stays put in `docker logs` instead of
scrolling away in an endless loop.

**Diagnosis:**
```bash
docker logs --tail 30 claude-code-dock
```

If you see a `✗ FATAL` block, it already tells you the fix — usually one of:
1. `AUTO_START_MODE` set to something other than `interactive`/`remote`/`shell`
2. `CONFIG_BASE_PATH` unset/misspelled, or the resolved directory on the host is not owned by UID 1000
3. `WORKSPACE_PATH` unset/misspelled, or not owned by UID 1000

After fixing `.env` or host permissions:
```bash
docker compose up -d --force-recreate
```

**If the container is genuinely still restarting** (not holding on a FATAL
message), the crash is happening somewhere validation doesn't cover —
investigate with a shell instead:
```bash
# Temporarily change AUTO_START_MODE to shell in .env
# AUTO_START_MODE=shell
docker compose up -d --force-recreate

# Connect and investigate
docker exec -it --user node claude-code-dock bash
```

Or start without entrypoint:
```bash
docker run --rm -it \
  --user node \
  --entrypoint /bin/bash \
  -v "${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}:/home/node/.claude" \
  -v "${WORKSPACE_PATH:-$(pwd)/workspaces}:/workspace" \
  claude-code-dock_claude-code-dock
```

---

### Container is "Up" and running, but Claude Code is unresponsive (marked `unhealthy`)

**Symptom:**
```
NAME               STATUS
claude-code-dock   Up 2 hours (unhealthy)
```

**Cause:** The Dockerfile's `HEALTHCHECK` failed (tmux session gone, or its pane is dead — e.g. a crashed `claude` process left the pane behind). `restart: unless-stopped` does **not** react to this on its own — it only restarts on the container actually exiting, and an `unhealthy` container is still running from Docker's point of view.

**Solution — restart it manually, or use the watchdog script:**
```bash
# One-off
docker restart claude-code-dock

# Or, checks health and restarts only if unhealthy (safe to run anytime)
./scripts/watchdog.sh
```

**Automate it** by running the watchdog from the host's cron, so an unhealthy container gets fixed without you noticing:
```cron
*/5 * * * * /path/to/claude-code-dock/scripts/watchdog.sh >> /path/to/claude-code-dock/watchdog.log 2>&1
```

---

## Connection Problems

### `attach.sh` does not connect or tmux session not found

**Symptom:** `./scripts/attach.sh` returns an error or the tmux session "main" does not exist.

**Cause:** The container may not be running or the tmux session has not been created yet.

**Solutions:**

```bash
# Check if the container is running
docker ps --filter name=claude-code-dock

# Check if the tmux session exists
docker exec claude-code-dock tmux list-sessions

# If Claude does not appear, check logs
docker logs --tail 10 claude-code-dock
```

---

### Stopped container — cannot connect

```bash
# Container is stopped -- start it again
docker compose up -d

# Check why it stopped
docker logs --tail 20 claude-code-dock
```

---

### Ctrl+B, D does not disconnect

**Cause:** Some terminals or SSH configurations intercept these keys.

**Solutions:**

```bash
# Option 1: Close the SSH terminal (Claude keeps running on the server)
# Option 2: Use the tmux command to detach
# Inside the tmux session, type: :detach
```

---

### Claude Code interface rendering incorrectly

**Symptom:** Strange characters, garbled interface, incorrect colors.

**Cause:** Incorrect `TERM` variable or terminal without color support.

**Solutions:**

```bash
# Check TERM inside the container
docker exec --user node claude-code-dock echo $TERM

# When connecting, force the correct TERM
TERM=xterm-256color docker exec -it --user node claude-code-dock tmux attach-session -t main

# If using local tmux, set tmux's TERM
echo 'set -g default-terminal "screen-256color"' >> ~/.tmux.conf
```

---

## Logs Problems

### `docker logs` / Unraid "Logs" tab shows nothing, or shows the terminal screen

**Symptom:** Opening the container's "Logs" tab in the Unraid Docker UI (or
running `docker logs claude-code-dock`) shows either nothing useful, or what
looks like a frozen/garbled snapshot of the Claude Code terminal instead of
scrolling log lines.

**Cause:** This is expected given this project's [PID 1
architecture](architecture.md). PID 1 is tmux running Claude Code as a
full-screen TUI attached to the container's tty. `docker logs` (and Unraid's
"Logs" button, which just calls `docker logs`) only captures raw stdout/stderr
— it has no concept of tmux's screen redraws, cursor movement, or the alternate
screen buffer, so it either mirrors whatever is currently on screen or appears
empty. It only shows clean, readable text during the entrypoint's own startup
phase, before Claude Code takes over the tty.

**Solution:** Use the persisted, plain-text startup log instead — it is written
by the entrypoint outside of tmux's control and survives restarts:

```bash
./scripts/logs.sh --app
```

or read it directly from the host, since it lives in the bind-mounted config
volume:

```bash
tail -f ./configs/<session>/logs/dock.log
```

To watch the live Claude Code session itself (not logs), use `./scripts/attach.sh`
or the Unraid container Console instead.

---

## Authentication Problems

### Claude Code asks for login every time the container restarts

**Cause:** The config volume is not being mounted correctly, `CONFIG_BASE_PATH`/`REMOTE_SESSION_NAME` changed between restarts, or credentials are not being persisted.

**Diagnosis:**
```bash
# Check if the session's config dir has content
ls -la "${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}/"

# Check if the volume is mounted correctly
docker inspect claude-code-dock | jq '.[0].Mounts'

# Check files inside the container
docker exec claude-code-dock ls -la /home/node/.claude/
```

**Solutions:**

**A) Config directory empty after login:**
Claude Code may have saved credentials in a different location. Check:
```bash
# After logging in, check where credentials were saved
docker exec claude-code-dock find /home/node -name "*.json" 2>/dev/null
docker exec claude-code-dock find /home/node -name "credentials*" 2>/dev/null
```

**B) Incorrect permission on the config directory:**
```bash
# Check permissions (must be accessible to UID 1000, or your PUID/PGID)
ls -la "${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}/"

# Fix
chown -R 1000:1000 "${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}/"
chmod 700 "${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}/"
```
(Or set `PUID`/`PGID` in `.env` to match the directory's existing owner instead — see the config-volume section above.)

**C) Volume not appearing in `docker inspect`, or `CONFIG_BASE_PATH`/`REMOTE_SESSION_NAME` changed:**
```bash
# The .env may not be loading, or these vars are unset/misspelled
cat .env

# Confirm both are set
grep -E "^(CONFIG_BASE_PATH|REMOTE_SESSION_NAME)=" .env

# Force container recreation with new settings
docker compose down
docker compose up -d
```

---

### "Authentication failed" or "Invalid token"

**Cause:** Credentials saved in the config directory may be corrupted or expired.

**Solution:**
```bash
CONFIG_DIR="${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}"

# 1. Back up current credentials
cp -r "${CONFIG_DIR}/" "${CONFIG_DIR}_backup_$(date +%Y%m%d)/"

# 2. Clear credentials
rm -rf "${CONFIG_DIR}"/*

# 3. Restart the container
docker compose restart

# 4. Reconnect and log in again
./scripts/attach.sh
```

---

## Workspace Problems

### Empty workspace inside the container

**Symptom:** Inside the container, `/workspace` is empty but the host directory has files.

**Diagnosis:**
```bash
# Check if workspace is mounted
docker exec claude-code-dock ls -la /workspace/

# Check WORKSPACE_PATH in .env
grep WORKSPACE_PATH .env

# Check mount
docker inspect claude-code-dock | jq '.[0].Mounts[] | select(.Destination == "/workspace")'
```

**Causes and solutions:**

**A) Incorrect WORKSPACE_PATH in .env:**
```bash
# Check if the path exists on the host
ls -la /your/workspace/path

# Fix .env and recreate the container
nano .env
docker compose down && docker compose up -d
```

**B) Relative path in .env not resolved:**
```bash
# Use absolute path in .env
# Change: WORKSPACE_PATH=./workspaces
# To:     WORKSPACE_PATH=/absolute/path/workspaces
```

---

### Permission denied when creating/editing files in workspace

```bash
# Check file ownership on the host
ls -la /your/workspace/

# The container runs as node (UID 1000 by default, or your PUID/PGID)
docker exec --user node claude-code-dock id

# If the workspace belongs to a different user on the host, either:
chown -R 1000:1000 /your/workspace/
# ...or set PUID/PGID in .env to that host user's uid/gid instead and
# restart -- the container remaps 'node' to match, no host chown needed:
#   PUID=$(id -u)
#   PGID=$(id -g)
# OR add write permission for all (fine for homelab):
chmod -R 777 /your/workspace/
```

---

## Performance Problems

### Claude Code slow or unresponsive

```bash
# Check resource usage
docker stats claude-code-dock --no-stream

# Check if there is a memory limit
docker inspect claude-code-dock | jq '.[0].HostConfig.Memory'

# Check host load
uptime
free -h
```

**Solution — raise the limits in `docker-compose.resources.yml`, then apply it:**
```yaml
# docker-compose.resources.yml
services:
  claude-code-dock:
    deploy:
      resources:
        limits:
          memory: 4g
```
```bash
docker compose -f docker-compose.yml -f docker-compose.resources.yml up -d
```
See [Docker Reference: Resource Limits](docker.md#resource-limits) for why this lives in a separate, opt-in overlay instead of `docker-compose.yml` itself.

---

### Slow workspace on HDD

```bash
# Check if workspace is on HDD
df -h /your/workspace/

# Move to SSD/NVMe if available
# On Unraid: use /mnt/cache instead of /mnt/user
```

---

## Pull / Build Problems

### Pull fails — registry unreachable or rate-limited

```bash
# Try again (may be temporary instability or an anonymous GHCR rate limit)
docker compose pull

# Fall back to building from source for this run
docker compose build
docker compose up -d
```

### Build fails — npm error

Only relevant if `CLAUDE_SOURCE_PATH` is set (building locally instead of pulling):

```bash
# Clear Docker cache and rebuild
docker system prune -f
docker compose build --no-cache
```

### Build fails — network timeout

```bash
# Try again (may be temporary instability)
docker compose build --no-cache

# Check server connectivity
curl -s https://registry.npmjs.org/@anthropic-ai/claude-code | jq '.["dist-tags"].latest'
```

### Build "succeeds" but serves a stale Claude Code / apt version

**Symptom:** the build log shows `CACHED` on the `apt-get upgrade` and/or
`npm install -g @anthropic-ai/claude-code@...` steps, even though you expected
a fresh build (e.g. after editing local source with `CLAUDE_SOURCE_PATH` set,
or just wanting the latest `claude` release).

**Cause:** `./scripts/install.sh`, `./scripts/update.sh`, and
`./scripts/session-up.sh` always build local (`CLAUDE_SOURCE_PATH`) images
with `--no-cache` specifically so these two layers can never be stale. **This
protection is bypassed whenever something calls `docker compose`/`docker
compose up --build` directly instead of going through those scripts** — most
commonly the **Unraid Compose Manager plugin**'s "Update Stack"/"Compose Up"
button, same class of issue as the container-name conflict above. A plain
rebuild through Compose Manager reuses Docker's local layer cache, so those
two `RUN` layers (and the `BUILD SOURCE: ...` line just after them) simply
don't execute again — no new apt patches, no new `claude` version, and no
build-source line in the log, even though the build reports success.

**Solution:** force a cache-free rebuild before/instead of using Compose
Manager's button, replacing `<container-name>` with this stack's actual
`CONTAINER_NAME` (check `.env` if unsure):
```bash
docker compose build --no-cache
docker compose up -d --force-recreate <container-name>
```
This always re-runs the apt/npm/build-source layers regardless of what
triggered the previous build.

---

### `up` fails after a successful build/pull — "Conflict. The container name ... is already in use"

**Symptom:** the image builds or pulls fine, but the final `up` step fails with
Docker's raw daemon error:
```
Error response from daemon: Conflict. The container name "/your-container-name"
is already in use by container "<id>". You have to remove (or rename) that
container to be able to reuse that name.
```

**Cause:** this is a configuration issue, not a build/pull failure — some
other container (usually a different session/stack, e.g. a `-dev`/`-test`
duplicate) already holds the exact `CONTAINER_NAME` this stack is trying to
use. It almost always means `.env` was copied from another session/project
without changing `CONTAINER_NAME` to something unique.

`./scripts/install.sh`, `./scripts/update.sh`, and `./scripts/session-up.sh`
already catch this and re-word it with the fix inline. **This raw form shows
up when something bypasses those scripts and calls `docker compose`
directly** — most commonly the **Unraid Compose Manager plugin**'s own
"Update Stack"/"Compose Up" button, which runs `docker compose pull`/`up`
itself.

**Solution:**
```bash
# 1. Edit this stack's .env and give it a unique name, e.g.:
CONTAINER_NAME=claude-code-dock-dev

# 2. Re-run the stack's "Compose Up" (Unraid) or:
docker compose up -d
```
If you don't recognize the other container holding the name, check what it
is before touching it — it may be an unrelated stack's already-running
session, not a stale leftover:
```bash
docker inspect --format '{{.Name}} — {{.Image}} — {{.State.Status}}' <id-from-the-error>
```

---

## Collecting Information for Bug Reports

If you need to report a bug, collect this information:

```bash
#!/bin/bash
echo "=== claude-code-dock Debug Info ==="
echo "Date: $(date)"
echo ""
echo "=== Docker Version ==="
docker --version
docker compose version
echo ""
echo "=== Container Status ==="
docker ps -a --filter name=claude-code-dock
echo ""
echo "=== Container Inspect ==="
docker inspect claude-code-dock 2>/dev/null | jq '.[0].State' || echo "Container not found"
echo ""
echo "=== Container User ==="
docker exec claude-code-dock whoami 2>/dev/null || echo "Container is not running"
echo ""
echo "=== Recent Logs ==="
docker logs --tail 30 claude-code-dock 2>/dev/null || echo "No logs available"
echo ""
echo "=== Volumes ==="
docker inspect claude-code-dock 2>/dev/null | jq '.[0].Mounts' || echo "N/A"
echo ""
echo "=== Host Info ==="
uname -a
echo ""
echo "=== .env file (without sensitive values) ==="
grep -v "^#" .env 2>/dev/null | grep -v "^$" | sed 's/=.*/=***/' || echo ".env not found"
```

Save the output of this script and include it when reporting the bug.
