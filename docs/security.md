# Security — claude-code-dock

For architecture details, see [Architecture](architecture.md). For general setup, see the [README](../README.md).

## Threat Model

claude-code-dock is designed for use in **personal and homelab environments** — a single user or family on a trusted private network. The threat model is different from a public web application.

**Threats considered:**
- Unauthorized access to the container via local network
- Accidental exposure of Claude Code credentials
- Compromise of the host server

**Out of scope (for personal homelab use):**
- Brute-force attacks from the internet (adequate firewall is assumed)
- Multi-tenancy (multiple untrusted users)

---

## Credential Protection

### What are Claude Code credentials?

Claude Code stores authentication credentials in the `~/.claude/` directory. In the container, this maps to `/home/node/.claude/` (user `node`, UID 1000), which is persisted in `CONFIG_BASE_PATH/REMOTE_SESSION_NAME/` on the host.

These credentials allow Claude Code to authenticate with Anthropic's servers.

### Best practices for protection

**1. Never commit the config directory to git:**

The `.gitignore` already excludes this directory. Verify periodically:

```bash
# Confirm the session's config dir is ignored
git check-ignore -v "${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}"
```

**2. Restricted permissions on the host:**

```bash
CONFIG_DIR="${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}"

# Set correct permissions
chmod 700 "${CONFIG_DIR}"
chmod 600 "${CONFIG_DIR}"/* 2>/dev/null || true

# Verify
ls -la "${CONFIG_DIR}"
```

**3. Encrypted backups:**

```bash
# Create encrypted backup with GPG
./scripts/backup.sh --output /tmp/backup-temp/
gpg --symmetric --cipher-algo AES256 \
    /tmp/backup-temp/claude-code-dock-backup-*.tar.gz

# Move encrypted backup to a safe location
mv /tmp/backup-temp/*.gpg /mnt/user/backups/
rm -rf /tmp/backup-temp/
```

**4. Never share the config directory:**

Anyone with access to `CONFIG_BASE_PATH/REMOTE_SESSION_NAME/` can use your Claude Code credentials.

---

## Container Security

### Non-root user (node, UID 1000)

The container runs as the `node` user (UID/GID 1000) — **not as root**. This is both a security and functional decision:

**Reasons:**
- Claude Code 2.x blocks `--dangerously-skip-permissions` when run as root
- Reduces the attack surface inside the container
- Follows container best practices

**Implications for volumes:**
- The workspace and config directory must be accessible to UID 1000
- On most homelabs (Unraid, Synology, etc.), volumes have broad permissions

```bash
# Verify current user in the container
docker exec claude-code-dock whoami
# -> node

docker exec claude-code-dock id
# -> uid=1000(node) gid=1000(node) groups=1000(node)
```

### No exposed ports

By design, claude-code-dock **does not expose any network ports**. Interaction is exclusively via terminal. This eliminates an entire category of network attacks.

```yaml
# docker-compose.yml -- there is no 'ports' section
# Correct -- no port exposure
```

### Network isolation (optional)

For greater isolation, restrict the container's network access:

```yaml
# docker-compose.yml
services:
  claude-code-dock:
    # ... other settings ...
    networks:
      - claude_network

networks:
  claude_network:
    driver: bridge
    internal: false  # false = allows internet access (required for Claude Code)
```

---

## Secure Remote Access

### Recommendation: SSH with public key

To access the server remotely and connect to Claude Code:

```bash
# 1. Generate SSH key (on the client computer)
ssh-keygen -t ed25519 -C "claude-code-dock-access"

# 2. Copy public key to the server
ssh-copy-id -i ~/.ssh/id_ed25519.pub user@your-server

# 3. Disable password authentication on the server (recommended)
# In /etc/ssh/sshd_config:
# PasswordAuthentication no
# PubkeyAuthentication yes

# 4. Connect to the server
ssh user@your-server

# 5. Connect to Claude Code
./scripts/attach.sh
```

### Recommendation: VPN for external access

If you need to access the server from outside your home network, use a VPN instead of exposing SSH to the internet:

**Recommended options:**
- **Tailscale** — easy setup, no public IP required
- **WireGuard** — high performance, manual configuration
- **ZeroTier** — alternative to Tailscale

```bash
# Example with Tailscale
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up

# After connecting via Tailscale
ssh user@100.x.x.x  # Tailscale IP of the server
./scripts/attach.sh
```

### NOT recommended: exposing the container to the internet

Do not expose the Docker container directly to the internet. Although the container does not expose ports, the host server must be protected.

---

## Filesystem Security

### Workspace

The workspace (`/workspace`) contains your projects. If using a shared directory on a NAS, verify:

```bash
# Check permissions
ls -la "${WORKSPACE_PATH}"

# Ensure only authorized users have access
chmod 750 "${WORKSPACE_PATH}"
```

### `.env` file

```bash
# Restricted permission for .env
chmod 600 .env

# Verify
ls -la .env
# -rw------- 1 user user ... .env
```

---

## What claude-code-dock Does NOT Do

It is important to make explicit what this project **does not do** for security and integrity reasons:

| Practice | Status | Reason |
|----------|--------|--------|
| Automate login | Never | Violates terms of use; insecure |
| Intercept tokens | Never | Would compromise credentials |
| Create custom OAuth | Never | Out of scope; not sustainable |
| Extract credentials | Never | Privacy violation |
| Authentication proxy | Never | Man-in-the-middle risk |
| Modify Claude Code | Never | Violates software integrity |

**The project only:**
- Provides a Docker environment to run the official Claude Code
- Persists the directories where Claude Code already stores its data
- Facilitates terminal access to the Claude Code process

---

## Security Audit

### Check what is being persisted

```bash
CONFIG_DIR="${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}"

# View all files in the config dir
find "${CONFIG_DIR}" -type f | sort

# View permissions
ls -laR "${CONFIG_DIR}"
```

### Check processes inside the container

```bash
# Running processes
docker exec claude-code-dock ps aux

# Open network connections
docker exec claude-code-dock ss -tlnp 2>/dev/null || \
docker exec claude-code-dock netstat -tlnp 2>/dev/null
```

### Scan image for known vulnerabilities

```bash
# With Docker Scout (requires Docker Desktop or login)
docker scout cves claude-code-dock_claude-code-dock

# With Trivy (open source)
trivy image claude-code-dock_claude-code-dock
```

---

## Security Checklist

```
[ ] CONFIG_BASE_PATH/REMOTE_SESSION_NAME/ has permission 700 on the host
[ ] CONFIG_BASE_PATH/REMOTE_SESSION_NAME/ is in .gitignore (verify with: git check-ignore -v <path>)
[ ] .env has permission 600
[ ] .env is in .gitignore
[ ] No Docker ports are exposed
[ ] Server access is via SSH with public key
[ ] Backups of the config directory are stored securely
[ ] The server is not directly exposed to the internet
[ ] VPN configured for external access (if needed)
[ ] Container runs as node user (not root) -- verify with: docker exec claude-code-dock whoami
```
