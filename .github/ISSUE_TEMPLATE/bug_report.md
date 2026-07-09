---
name: Bug report
about: Something in claude-code-dock isn't working as expected
title: ""
labels: bug
---

**Before filing:** check [docs/troubleshooting.md](../../docs/troubleshooting.md) — it covers most startup, connection, login, and workspace-permission problems already.

## Setup

- Which of the [four setup profiles](../../docs/getting-started.md#which-setup-is-yours) are you on? (default / remote / with GitHub / CLAUDE_SOURCE_PATH contributor build)
- `AUTO_START_MODE`: <!-- interactive / remote / shell -->
- Platform: <!-- Linux / Unraid / Synology / QNAP / TrueNAS / Proxmox / other -->
- Image source: <!-- pulled ghcr.io tag, or CLAUDE_SOURCE_PATH local build -->
- `claude --version` inside the container (`docker exec <container> claude --version`):

## What happened

<!-- What you expected vs. what actually happened -->

## Steps to reproduce

1.
2.
3.

## Relevant logs

<!--
docker logs --tail 50 <container>
or the persistent startup log: ./scripts/logs.sh --app
Redact anything sensitive (tokens, paths you don't want public) before pasting.
-->

```
paste here
```
