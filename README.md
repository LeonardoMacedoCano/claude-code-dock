# Claude Code Dock

**Run Claude Code persistently on a 24/7 server — always on, always authenticated, accessible from any device.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/Docker-Ready-2496ED?logo=docker)](https://www.docker.com/)
[![Unraid](https://img.shields.io/badge/Unraid-Compatible-F15A2C)](https://unraid.net/)

**Jump to:** [What It Solves](#what-it-solves) · [Is This For You?](#is-this-for-you) · [Example](#example) · [Quick Start](#quick-start) · [Documentation](#documentation)

---

## What It Solves

Claude Remote Control requires Claude to already be running on your machine before you connect. Close the terminal, leave home, let the laptop sleep — the session is gone.

**claude-code-dock fixes that.** It runs Claude inside a Docker container on a server that never turns off. Boot, stay running, survive disconnects. Open Claude.ai from anywhere and your sessions are already there.

If a session freezes (Claude stuck waiting for a permission prompt), VPN into your server, attach to the tmux session, unblock it, detach. No physical access needed.

---

## Is This For You?

**Yes, if you:**
- Have a server that stays on 24/7 (homelab, Unraid, NAS, VPS, Raspberry Pi)
- Want Claude Remote Control available from any device without preparing anything in advance
- Want multiple projects each with their own persistent Claude session

**No, if you:**
- Don't have a 24/7 server
- Only use Claude Code on your local machine — just install `@anthropic-ai/claude-code` directly

---

## Example

You have a website running on your server. One container, pointed at the production folder:

```env
REMOTE_SESSION_NAME=HomePage
WORKSPACE_PATH=/srv/www/myhomepage.com
AUTO_START_MODE=remote
```

From Claude.ai Remote Control, select `HomePage` and ask: *"Update the About page with my new contact info."* Claude is running directly on the server, in the production folder, with your files — from your phone, from anywhere.

One server can run any number of containers, each with its own project and session name, all sharing the same Claude login.

---

## Quick Start

No local clone required — `docker compose pull` fetches the prebuilt, CI-published image from GHCR.

```bash
mkdir -p /srv/projects/homepage && cd /srv/projects/homepage
curl -o docker-compose.yml https://raw.githubusercontent.com/LeonardoMacedoCano/claude-code-dock/main/docker-compose.yml
curl -o .env https://raw.githubusercontent.com/LeonardoMacedoCano/claude-code-dock/main/.env.example
# edit .env: set REMOTE_SESSION_NAME, WORKSPACE_PATH, CONFIG_BASE_PATH
docker compose pull && docker compose up -d
docker exec -it --user node <container-name> tmux attach-session -t main   # first login only
```

That covers the default setup. Want GitHub push/pull from inside the container, Remote Control, or to run several projects from one clone? → **[Full Getting Started guide](docs/getting-started.md)**, which covers every `.env` profile, the multi-project session scripts, and all management scripts (`attach.sh`, `backup.sh`, `update.sh`, ...).

---

## Compatibility

| Platform | Status |
|----------|--------|
| Linux x86_64 / ARM64 (Raspberry Pi 4/5) | Supported |
| Unraid 6.10+ | Supported — see [Unraid Guide](docs/unraid.md) |
| Synology DSM / QNAP QTS / TrueNAS Scale | Supported |
| Proxmox (Linux VM) | Supported |

---

## Documentation

| Document | Description |
|----------|-------------|
| [Getting Started](docs/getting-started.md) | `.env` profiles, step-by-step setup, execution modes, scripts reference |
| [Docker Reference](docs/docker.md) | Docker commands, volumes, logs, **full environment variable reference** |
| [Git & GitHub Integration](docs/git-integration.md) | Commit identity, push/pull auth, auto-clone on startup |
| [Unraid Guide](docs/unraid.md) | Complete Unraid setup |
| [Troubleshooting](docs/troubleshooting.md) | Common problems and solutions |
| [Security](docs/security.md) | Credential protection, remote access |
| [Architecture](docs/architecture.md) | tmux/PID 1 design, data flow, technical decisions |
| [CONTRIBUTING](CONTRIBUTING.md) | Dev setup, test suite, PR checklist |

Deep architecture/decision reference for contributors and AI agents: [CLAUDE.md](CLAUDE.md).

---

claude-code-dock is an independent open source project, not affiliated with Anthropic. [MIT License](LICENSE)
