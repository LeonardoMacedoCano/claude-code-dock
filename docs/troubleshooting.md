# Troubleshooting Guide — ClaudeDock

For architecture details, see [Architecture](architecture.md). For Docker commands reference, see [Docker Reference](docker.md).

## Quick Diagnosis

Before any specific troubleshooting, collect this information:

```bash
# Container status
docker ps -a --filter name=claude-dock

# Last 50 lines of logs
docker logs --tail 50 claude-dock

# Docker version
docker --version
docker compose version

# Resource usage
docker stats claude-dock --no-stream

# Container system info
docker exec claude-dock uname -a
docker exec claude-dock node --version
docker exec claude-dock claude --version
docker exec claude-dock whoami  # should show 'node'
```

---

## Startup Problems

### Container does not start — "Exited (1)"

**Symptom:**
```
claude-dock   Exited (1) 2 seconds ago
```

**Diagnosis:**
```bash
docker logs claude-dock
```

**Causes and solutions:**

**A) Permission error on the `./config` volume:**
```
Error: EACCES: permission denied, open '/home/node/.claude/...'
```
```bash
# Fix permissions (UID 1000 = node user)
chown -R 1000:1000 ./config/
chmod -R 700 ./config/
```

**B) WORKSPACE_PATH does not exist:**
```
Error response from daemon: invalid mount config for type "bind": bind source path does not exist
```
```bash
# Create the directory on the host
mkdir -p /your/workspace/path
```

**C) Image was not built:**
```
Unable to find image 'claude-dock:latest' locally
```
```bash
docker compose build
```

---

### Container starts but stops immediately

**Diagnosis:**
```bash
# View exit code
docker inspect claude-dock | jq '.[0].State'

# View full logs
docker logs claude-dock
```

**Cause A — Claude Code not found in the image:**
```
[x] Claude Code not found in PATH.
```
```bash
# Rebuild image without cache
docker compose build --no-cache
docker compose up -d
```

**Cause B — Entrypoint permission problem:**
```bash
# Check entrypoint permissions
docker run --rm --entrypoint ls \
  claude-dock_claude-dock \
  -la /usr/local/bin/entrypoint.sh

# If needed, rebuild
docker compose build --no-cache
```

---

### Container restart loop

**Symptom:**
```
NAME          STATUS
claude-dock   Restarting (1) 3 seconds ago
```

**Diagnosis:**
```bash
# View loop logs
docker logs --tail 20 claude-dock
```

**Diagnostic solution — start with shell:**
```bash
# Temporarily change AUTO_START_MODE to shell in .env
# AUTO_START_MODE=shell
docker compose up -d --force-recreate

# Connect and investigate
docker exec -it claude-dock bash
```

Or start without entrypoint:
```bash
docker run --rm -it \
  --user node \
  --entrypoint /bin/bash \
  -v "$(pwd)/config:/home/node/.claude" \
  -v "${WORKSPACE_PATH:-$(pwd)/workspaces}:/workspace" \
  claude-dock_claude-dock
```

---

## Connection Problems

### `attach.sh` does not connect or tmux session not found

**Symptom:** `./scripts/attach.sh` returns an error or the tmux session "main" does not exist.

**Cause:** The container may not be running or the tmux session has not been created yet.

**Solutions:**

```bash
# Check if the container is running
docker ps --filter name=claude-dock

# Check if the tmux session exists
docker exec claude-dock tmux list-sessions

# If Claude does not appear, check logs
docker logs --tail 10 claude-dock
```

---

### Stopped container — cannot connect

```bash
# Container is stopped -- start it again
docker compose up -d

# Check why it stopped
docker logs --tail 20 claude-dock
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
docker exec claude-dock echo $TERM

# When connecting, force the correct TERM
TERM=xterm-256color docker exec -it claude-dock tmux attach-session -t main

# If using local tmux, set tmux's TERM
echo 'set -g default-terminal "screen-256color"' >> ~/.tmux.conf
```

---

## Authentication Problems

### Claude Code asks for login every time the container restarts

**Cause:** The `./config` volume is not being mounted correctly, or credentials are not being persisted.

**Diagnosis:**
```bash
# Check if ./config has content
ls -la ./config/

# Check if the volume is mounted correctly
docker inspect claude-dock | jq '.[0].Mounts'

# Check files inside the container
docker exec claude-dock ls -la /home/node/.claude/
```

**Solutions:**

**A) `./config` directory empty after login:**
Claude Code may have saved credentials in a different location. Check:
```bash
# After logging in, check where credentials were saved
docker exec claude-dock find /home/node -name "*.json" 2>/dev/null
docker exec claude-dock find /home/node -name "credentials*" 2>/dev/null
```

**B) Incorrect permission on `./config` directory:**
```bash
# Check permissions (must be accessible to UID 1000)
ls -la ./config/

# Fix
chown -R 1000:1000 ./config/
chmod 700 ./config/
```

**C) Volume not appearing in `docker inspect`:**
```bash
# The .env may not be loading
cat .env

# Check CONFIG_PATH in .env
grep CONFIG_PATH .env

# Force container recreation with new settings
docker compose down
docker compose up -d
```

---

### "Authentication failed" or "Invalid token"

**Cause:** Credentials saved in `./config` may be corrupted or expired.

**Solution:**
```bash
# 1. Back up current credentials
cp -r ./config/ ./config_backup_$(date +%Y%m%d)/

# 2. Clear credentials
rm -rf ./config/*

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
docker exec claude-dock ls -la /workspace/

# Check WORKSPACE_PATH in .env
grep WORKSPACE_PATH .env

# Check mount
docker inspect claude-dock | jq '.[0].Mounts[] | select(.Destination == "/workspace")'
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

# The container runs as node (UID 1000)
docker exec claude-dock id

# If the workspace belongs to a different user on the host:
chown -R 1000:1000 /your/workspace/
# OR add write permission for all (fine for homelab):
chmod -R 777 /your/workspace/
```

---

## Performance Problems

### Claude Code slow or unresponsive

```bash
# Check resource usage
docker stats claude-dock --no-stream

# Check if there is a memory limit
docker inspect claude-dock | jq '.[0].HostConfig.Memory'

# Check host load
uptime
free -h
```

**Solution — increase limits in docker-compose.yml:**
```yaml
deploy:
  resources:
    limits:
      memory: 4G
```

---

### Slow workspace on HDD

```bash
# Check if workspace is on HDD
df -h /your/workspace/

# Move to SSD/NVMe if available
# On Unraid: use /mnt/cache instead of /mnt/user
```

---

## Build Problems

### Build fails — npm error

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

---

## Collecting Information for Bug Reports

If you need to report a bug, collect this information:

```bash
#!/bin/bash
echo "=== ClaudeDock Debug Info ==="
echo "Date: $(date)"
echo ""
echo "=== Docker Version ==="
docker --version
docker compose version
echo ""
echo "=== Container Status ==="
docker ps -a --filter name=claude-dock
echo ""
echo "=== Container Inspect ==="
docker inspect claude-dock 2>/dev/null | jq '.[0].State' || echo "Container not found"
echo ""
echo "=== Container User ==="
docker exec claude-dock whoami 2>/dev/null || echo "Container is not running"
echo ""
echo "=== Recent Logs ==="
docker logs --tail 30 claude-dock 2>/dev/null || echo "No logs available"
echo ""
echo "=== Volumes ==="
docker inspect claude-dock 2>/dev/null | jq '.[0].Mounts' || echo "N/A"
echo ""
echo "=== Host Info ==="
uname -a
echo ""
echo "=== .env file (without sensitive values) ==="
grep -v "^#" .env 2>/dev/null | grep -v "^$" | sed 's/=.*/=***/' || echo ".env not found"
```

Save the output of this script and include it when reporting the bug.
