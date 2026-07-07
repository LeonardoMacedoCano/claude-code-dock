# Contributing to claude-code-dock

Thanks for considering a contribution. This file gets you from clone to
opened PR; for the full architecture/design reasoning behind *why* things
are built the way they are, see [CLAUDE.md](CLAUDE.md) — read it before any
non-trivial change, especially before touching `docker/entrypoint.sh`,
`Dockerfile`, or `docker-compose.yml`.

## The one rule that matters most

The process selected by `AUTO_START_MODE` is always **PID 1** of the
container (tmux in interactive/remote mode, bash in shell mode). Almost
every other design decision in this repo follows from that. Don't break the
`exec` chain in `docker/entrypoint.sh`, and don't reintroduce a wrapper
process in front of it. See [CLAUDE.md § Architecture](CLAUDE.md#architecture)
for the full reasoning.

## Dev setup

1. Fork and clone the repo.
2. Copy `.env.example` to `.env` and fill in `WORKSPACE_PATH`,
   `CONFIG_BASE_PATH`, `REMOTE_SESSION_NAME` (see the
   [Which Setup Is Yours?](README.md#which-setup-is-yours) profiles in the
   README if you're unsure what else to set).
3. Point the build at your local working tree instead of pulling the
   published image or GitHub:
   ```env
   CLAUDE_SOURCE_PATH=.
   ```
   This always wins over `CLAUDE_DOCK_TAG`/`CLAUDE_DOCK_VERSION` when set —
   see [docs/docker.md#local-development](docs/docker.md#local-development)
   for the one gotcha (`docker compose up -d` alone won't rebuild; use
   `docker compose build --no-cache && docker compose up -d`, or
   `docker compose up -d --build`).
4. Build and start:
   ```bash
   docker compose build --no-cache
   docker compose up -d
   ```

## Running the test suite

```bash
bash tests/run.sh
```

Requires `shellcheck` and [`bats`](https://github.com/bats-core/bats-core)
(`npm install -g bats`, `apt install bats`, or `brew install bats-core`).
This runs shellcheck over every script plus the full `.bats` suite in
`tests/` (entrypoint validation, PUID/PGID remap, backup/restore,
healthcheck, watchdog, session scripts).

## Before opening a PR

1. **Document the reason for the change** in the PR description — this
   project's design decisions are deliberate and documented in `CLAUDE.md`;
   explain what you're changing and why, especially if it touches an
   existing documented decision.
2. Test on a clean build: `CLAUDE_SOURCE_PATH=.` + `docker compose build
   --no-cache` (never rely on Docker's layer cache or an already-tagged
   image to prove a change works).
3. Test all three execution modes if your change could plausibly affect
   startup: `AUTO_START_MODE=interactive`, `remote`, `shell`.
4. Verify credentials persist across `docker compose restart` if your
   change touches `~/.claude`, the config volume, or `entrypoint.sh`.
5. Run `bash tests/run.sh` and keep it green.
6. Match the existing shell style: `set -euo pipefail` (entrypoint.sh uses
   `set -eo pipefail`, intentionally — see `CLAUDE.md`), `snake_case()`
   functions, errors to `stderr`. No comments by default — only add one
   when the *why* isn't obvious from the code itself.

## What not to do

- Don't add dependencies to the image without clear justification.
- Don't automate or intercept Claude Code's login flow in any way — see
  [CLAUDE.md § Why not automate login?](CLAUDE.md#1-why-not-automate-login).
- Don't expose network ports without a clearly documented need — this
  project's whole security posture depends on zero exposed ports.
- Don't reintroduce a permanent `USER` directive in the `Dockerfile` or
  otherwise make the container run as root — see
  [CLAUDE.md § Non-root user](CLAUDE.md#non-root-user-node-uidgid-puidpgid-default-10001000).

## Reporting bugs / requesting features

Use the issue templates — they ask for the information needed to reproduce
(execution mode, which of the [four setup profiles](README.md#which-setup-is-yours)
you're on, relevant logs). Check [docs/troubleshooting.md](docs/troubleshooting.md)
first; it covers most common problems already.
