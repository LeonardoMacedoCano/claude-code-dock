# Git & GitHub Integration — claude-code-dock

How to let Claude commit and push from inside the container. For protecting
the token once it's configured (threat model, trust boundary), see
[Security: Credential Protection](security.md#credential-protection).

## Git identity

`GIT_USER_NAME` and `GIT_USER_EMAIL` set your commit identity inside the
container. Without them, commits have no author identity.

## GitHub authentication (push/pull)

`GITHUB_TOKEN_FILE` authenticates push/pull to GitHub — without it, `git
push` fails (public repos and read-only clones still work).

**Setup:**
1. Create a token — prefer a **fine-grained token** scoped to only the repo(s) this session needs: [github.com/settings/personal-access-tokens](https://github.com/settings/personal-access-tokens) → **Generate new token** → **Repository access: Only select repositories** → pick the repo(s) → under **Repository permissions**, grant **Contents: Read and write** (add **Pull requests: Read and write** if Claude will also open PRs) → generate and copy.
   A classic token ([github.com/settings/tokens](https://github.com/settings/tokens) → scope `repo`) also works, but grants push access to *every* repo on the account — only use it if you specifically need that breadth. A leaked token is only as bounded as its own scope (see [Security](security.md#credential-protection)).
2. Save it to a file **on the host** (not in `.env`):
   ```bash
   mkdir -p /srv/claude-secrets
   echo -n "github_pat_xxx..." > /srv/claude-secrets/github_token
   chmod 600 /srv/claude-secrets/github_token
   ```
3. Point `.env` at it:
   ```env
   GITHUB_TOKEN_FILE=/srv/claude-secrets/github_token
   ```
4. `docker compose up -d` (or `--force-recreate` if the container is already running).

`docker-compose.yml` mounts that file automatically, read-only, into the
container — no volume editing, no manual credential commands. Leave
`GITHUB_TOKEN_FILE` empty to skip GitHub auth entirely; the compose file
mounts a harmless `/dev/null` in that case, so nothing breaks either way.

**Note:** the token's value never sits in `.env`, a `docker-compose.yml
environment:` line, or the host shell's process environment — only the file
path does. The file's *content* is still readable via `docker exec
<container> cat /run/secrets/github_token` by anyone with Docker daemon
access on this host, same trust boundary as any other bind-mounted file. See
[Security](security.md#credential-protection) for the full threat model.

## Sharing one token across several instances

`GITHUB_TOKEN_FILE` is just a host path — nothing about it is
session-specific. Two legitimate patterns, both already fully supported with
no extra configuration:

- **Per-instance token:** each session's `.env` points at its own token
  file (e.g. `instances/<name>/github_token.txt`), scoped to only the
  repo(s) that instance touches.
- **Shared token:** several sessions' `.env` files all point at the *same*
  file (e.g. `shared/github/github_token.txt`) — useful when every instance
  pushes/pulls under the same GitHub identity and there's no reason to keep
  separate tokens around.

Pick whichever matches how you actually think about your instances; nothing
in claude-code-dock enforces one over the other. Sharing does widen blast
radius — a leak from any one instance exposes the
token to whatever it can reach, not just that instance's own repo(s) — so
prefer a token scoped as narrowly as the *widest* thing any sharing instance
actually needs, not the narrowest.

## Auto-clone on startup

Set `GIT_REPO_URL` to an HTTPS URL and the container clones the repository
into `/workspace` automatically on the first start, as long as the workspace
is empty.

```env
GIT_REPO_URL=https://github.com/your-user/your-repo.git
```

> **HTTPS only.** SSH URLs (`git@github.com:...`) are not supported — the
> container has no SSH keys. Always use the `https://` form. Private repos
> require `GITHUB_TOKEN_FILE`.

---

[← Back to README](../README.md) · [Full environment variable reference](docker.md#environment-variables)
