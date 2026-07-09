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

**3. Encrypted backups (recommended, especially for offsite/NAS destinations):**

`scripts/backup.sh` supports encryption natively — no manual `gpg` piping needed:

```bash
# Prompts for a passphrase interactively (GPG symmetric, AES256)
./scripts/backup.sh --encrypt

# Non-interactive (e.g. from cron): set a passphrase via env or .env
BACKUP_ENCRYPT_PASSPHRASE='your-strong-passphrase' ./scripts/backup.sh --encrypt
```

This produces `claude-code-dock-backup-*.tar.gz.gpg` instead of the plaintext archive. Restore with:

```bash
gpg --decrypt claude-code-dock-backup-2024-01-01_12-00-00.tar.gz.gpg > backup.tar.gz
./scripts/restore.sh backup.tar.gz
```

Requires `gpg` on the host running the backup script (not inside the container).

To have this run automatically instead of relying on remembering to do it, set `BACKUP_ENCRYPT_PASSPHRASE` in `.env` and run `./scripts/install.sh --with-backup-cron` — it adds a daily host crontab entry and automatically includes `--encrypt` when that passphrase is already set (see [Docker Reference: Backups](docker.md#backups)).

**4. Never share the config directory:**

Anyone with access to `CONFIG_BASE_PATH/REMOTE_SESSION_NAME/` can use your Claude Code credentials.

**5. Known limitation — env vars are visible via the Docker daemon:**

Any value passed through `environment:` in `docker-compose.yml` is stored in plain text in the container's process environment. Anyone with access to the Docker daemon on this host can read it with:

```bash
docker inspect claude-code-dock --format '{{.Config.Env}}'
docker exec claude-code-dock env
```

This is not a bug specific to claude-code-dock — it's how container env vars work in Docker generally. It matches this project's threat model (single trusted user/host, see below), but it does mean "anyone who can run `docker` commands on this host" is inside the trust boundary, same as anyone who can read `.env` on disk.

The GitHub token specifically avoids this: `GITHUB_TOKEN_FILE` in `.env` holds a *host path*, not the token itself, and `docker-compose.yml` mounts that file, read-only, at the fixed in-container path `/run/secrets/github_token` — so the token's value is never in `.env`, never in a `docker-compose.yml environment:` line, and never in `docker inspect --format '{{.Config.Env}}'` output. It narrows *where the token sits at rest*, not the daemon-access trust boundary above: `docker exec claude-code-dock cat /run/secrets/github_token` still reads it, same as any other bind-mounted file.

**6. The most realistic exfiltration path is the agent itself, not an external attacker.**

The token flows into `~/.git-credentials` in plaintext (`chmod 600`, but plaintext) so `git push`/`git pull` work non-interactively (see `entrypoint.sh`). That file lives in the same filesystem namespace Claude Code operates in. If `CLAUDE_AUTO_APPROVE=true` (`--dangerously-skip-permissions`) is set, Claude executes shell commands without per-action confirmation — including, hypothetically, commands suggested by content it reads, such as instructions embedded in a file inside a cloned/untrusted repository (a prompt-injection scenario). In that scenario the attacker doesn't need to compromise the container or the Docker daemon at all: the agent itself is the one with read access to the token, and auto-approve removes the human checkpoint that would normally catch an unexpected `curl` or `cat ~/.git-credentials` in a proposed command.

This is not a bug in claude-code-dock — it's a consequence of combining "credentials readable by the workspace process" (required for git push/pull to work at all) with "no human reviews each command" (what `CLAUDE_AUTO_APPROVE` explicitly opts into). It does mean the two should be considered together, not independently:

- Treat `CLAUDE_AUTO_APPROVE=true` as appropriate only for workspaces/repositories you trust the *content* of, not just the host environment — a malicious `README.md` or issue comment in a repo you clone is enough to act as the attack's entry point.
- If you routinely point this container at repositories you don't fully trust (forks, third-party PRs, scratch clones), prefer `CLAUDE_AUTO_APPROVE=false` for that session, or use a `GITHUB_TOKEN_FILE` pointing at a token scoped to the narrowest possible repo/permission set (fine-grained PAT, single repo, no admin scopes) so a leak is bounded.
- A leaked token is revocable and bounded in blast radius if scoped narrowly; a leaked token with broad `repo` scope across your whole account is not.

---

## Container Security

### Non-root user (node, UID/GID 1000 by default, remappable via PUID/PGID)

The actual long-running process (bash/tmux/claude) always runs as the `node` user — **never as root**. This is both a security and functional decision:

**Reasons:**
- Claude Code 2.x blocks `--dangerously-skip-permissions` when run as root
- Reduces the attack surface inside the container
- Follows container best practices

**How it works:** the image itself starts as root (needed so `entrypoint.sh` can `usermod`/`groupmod` the `node` account to `PUID`/`PGID` if set), then immediately drops privilege via `setpriv` before running anything else. `PUID`/`PGID=0` is refused outright — there is no way to make this container's Claude process actually run as root.

**Implications for volumes:**
- The workspace and config directory must be accessible to the resulting UID (1000 by default, or your `PUID`/`PGID`)
- On most homelabs (Unraid, Synology, etc.), volumes have broad permissions — but where they don't, prefer setting `PUID`/`PGID` to match the host owner over loosening the host directory's permissions

```bash
# Verify current user in the container -- note --user node: a bare `docker
# exec` now defaults to root (the image's default user), so this flag is
# required to see what the actual Claude Code process runs as
docker exec --user node claude-code-dock whoami
# -> node

docker exec --user node claude-code-dock id
# -> uid=1000(node) gid=1000(node) groups=1000(node)  (or your PUID/PGID)
```

### No exposed ports

By design, claude-code-dock **does not expose any network ports**. Interaction is exclusively via terminal. This eliminates an entire category of network attacks.

```yaml
# docker-compose.yml -- there is no 'ports' section
# Correct -- no port exposure
```

### Known exception — the optional watchdog sidecar

Everything above assumes the default setup: no exposed ports, no host-level
privilege needed. The one deliberate exception is opt-in and off by default:
`docker-compose.watchdog.yml` (see [Docker Reference: Watchdog](docker.md#watchdog))
mounts `/var/run/docker.sock` read-write into a small sidecar container so it
can restart the main container when Docker reports it unhealthy. Docker
socket access is root-equivalent on the host — it is not scoped to just this
project's container. Prefer `./scripts/install.sh --with-watchdog` (a plain
host crontab entry, no socket exposure) unless this host genuinely has no
cron access; only reach for the sidecar as a last resort, and understand that
enabling it changes this section's "no exposed ports / no host privilege"
guarantee for that one additional container.

### Known exception — the permission-fixing init container

The other deliberate exception, also opt-out-free but bounded and always on:
`docker-compose.yml` declares a `claude-code-dock-init` service (`alpine:3`)
that runs once, as root (its default user — no `user:` override), before the
main container starts. Its only job is `mkdir -p` + `chown -R "$PUID:$PGID"`
on `WORKSPACE_PATH` and `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` — the same two
host paths the main service already mounts, nothing else. This exists
because Docker itself auto-creates a missing bind-mount source directory as
`root:root` the instant a container starts, which is otherwise a guaranteed
"Config directory is not writable" failure the very first time a new
`REMOTE_SESSION_NAME` is started via a bare `docker compose up -d` (e.g.
Unraid's Compose Manager plugin, or any tool that isn't this project's own
`install.sh`/`new-session.sh`, which already did this chown from the host
side directly).

Why this is bounded, unlike a generic root-in-container concern:
- It touches only the two paths this same Compose file already declares as
  volumes for the main service — never an arbitrary host path, and never
  more than `WORKSPACE_PATH`/`CONFIG_BASE_PATH/REMOTE_SESSION_NAME`.
- It is best-effort: a `chown` failure (e.g. NFS with root-squash) is caught
  and only logged, so this container always exits `0` — it can never hang
  the stack or block the main container from starting.
- It exits immediately after the `chown` — there is no long-running root
  process, unlike the watchdog sidecar's `docker.sock` mount above, which
  keeps a root-equivalent capability available for the container's entire
  lifetime.
- It runs entirely inside the two bind-mounted paths' own filesystem view —
  it never mounts `/var/run/docker.sock` or anything else host-wide.

If this host's filesystem genuinely cannot support being chowned this way
(e.g. a network share with root-squash), the init container's warning is
harmless and the main container still starts, falling through to
`entrypoint.sh`'s own `fatal()` message with the same manual `chown` hint
this init container tries to make unnecessary in the first place.

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
[ ] Backups of the config directory are stored securely (prefer scripts/backup.sh --encrypt) and actually happen on a schedule, not only when remembered manually (`./scripts/install.sh --with-backup-cron`)
[ ] The server is not directly exposed to the internet
[ ] VPN configured for external access (if needed)
[ ] Container runs as node user (not root) -- verify with: docker exec claude-code-dock whoami
[ ] CLAUDE_AUTO_APPROVE is false unless you've deliberately decided to trust this workspace
[ ] Anyone with `docker` access to this host is treated as trusted (env vars are readable via docker inspect/exec; the mounted GITHUB_TOKEN_FILE content is readable via docker exec)
[ ] If CLAUDE_AUTO_APPROVE=true, the token behind GITHUB_TOKEN_FILE is scoped as narrowly as possible (fine-grained PAT, single repo) -- with auto-approve on, the agent itself (not just the host) can read ~/.git-credentials
[ ] If CLAUDE_AUTO_APPROVE=true, resource limits are set (size docker-compose.resources.yml and run with `-f docker-compose.yml -f docker-compose.resources.yml`) -- with no per-command confirmation, nothing else caps how much CPU/memory a single command can consume
[ ] docker-compose.watchdog.yml is NOT in use unless this host has no cron access -- it mounts /var/run/docker.sock (root-equivalent host access) into a sidecar container; prefer `./scripts/install.sh --with-watchdog` (host crontab, no socket exposure)
[ ] claude-code-dock-init exited 0 after the last `docker compose up` (`docker inspect --format '{{.State.ExitCode}}' <container_name>-init`) -- an exited container with code 0 here is expected and healthy, not a crash; a non-zero exit or a warning in its logs means WORKSPACE_PATH/CONFIG_BASE_PATH could not be chowned and the main container may still fail with a writability fatal()
```
