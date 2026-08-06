# Usage Patterns — claude-code-dock

claude-code-dock runs Claude Code as a persistent, isolated instance. What
that instance *represents* is entirely up to you — this page shows the three
generic patterns operators actually use it for, with no assumption that an
instance is a Git repository. See
[Getting Started](getting-started.md) for the step-by-step `.env` walkthrough
and [Docker Reference: Multiple Instances](docker.md#multiple-instances) for
running several of these side by side.

---

## An instance is not necessarily a Git repository

Three independent, fully optional variables decide whether Git is involved
at all, and how:

| Variable | Effect if unset |
|---|---|
| `GIT_REPO_URL` | No auto-clone — `/workspace` starts empty (or however it already looks on the host) |
| `GITHUB_TOKEN_FILE` | No push/private-pull authentication — public repos still clone/pull fine, `git push` just fails |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | Commits made inside the container have no author identity |

None of these gate anything else. A `WORKSPACE_PATH` with no `.git` folder
in it at all works exactly the same as one that is a full GitHub-tracked
repo — claude-code-dock never inspects the workspace to decide behavior.

---

## Pattern 1 — Git-versioned project

The instance mirrors one GitHub-tracked project. Claude can pull, commit,
and push.

```env
REMOTE_SESSION_NAME=web-project
WORKSPACE_PATH=/projects/web-project
CONFIG_BASE_PATH=/srv/claude-config
GIT_REPO_URL=https://github.com/example/web-project.git
GIT_USER_NAME=Your Name
GIT_USER_EMAIL=you@example.com
GITHUB_TOKEN_FILE=/srv/claude-secrets/github_token
```

On first start (empty `/workspace`), the repo is cloned automatically. See
[Git & GitHub Integration](git-integration.md) for token setup.

---

## Pattern 2 — Local workspace, no Git

A personal or scratch workspace with no version control at all — notes, a
personal dataset, an experiment.

```env
REMOTE_SESSION_NAME=personal-notes
WORKSPACE_PATH=/workspace/personal-notes
CONFIG_BASE_PATH=/srv/claude-config
```

No `GIT_*` variable is set. Claude works on the files in `/workspace`
exactly the same way; it just never has push/pull credentials or an
upstream to sync with. `git init`/local-only commits inside the container
still work fine if you want history without a remote — only push to GitHub
needs `GITHUB_TOKEN_FILE`.

---

## Pattern 3 — Multi-project / general-purpose workspace

One instance's `/workspace` contains several unrelated project folders —
useful for a "scratch" or "general" instance that isn't tied to one repo.

```env
REMOTE_SESSION_NAME=general
WORKSPACE_PATH=/workspace/general
CONFIG_BASE_PATH=/srv/claude-config
```

```
/workspace/general/
├── experiment-a/
├── experiment-b/
├── temporary-project/
└── notes/
```

claude-code-dock has no concept of "one instance = one project" — it mounts
whatever directory `WORKSPACE_PATH` points at, and Claude Code navigates
within it like any filesystem. `GIT_REPO_URL` doesn't make sense here (there
isn't one single repo to clone), but individual subfolders can each be their
own Git checkout if you set them up that way manually — claude-code-dock
doesn't need to know either way.

---

## Choosing what an instance represents

An instance (`REMOTE_SESSION_NAME`) can represent, interchangeably:

- **A project** — Pattern 1, one Git repo per instance.
- **An environment** — e.g. a staging/homologation instance for a project,
  distinct from its production counterpart, each with its own
  `REMOTE_SESSION_NAME` and config.
- **A personal workspace** — Pattern 2, notes or personal files with no
  repo.
- **A multi-project workspace** — Pattern 3, a scratch area covering several
  unrelated folders.

Nothing in claude-code-dock enforces one of these over another — pick
whichever matches how you actually think about that instance, and mix
patterns freely across instances on the same host (see
[Multiple Instances](docker.md#multiple-instances) for running several at
once via `new-session.sh`/`session-up.sh`/`sessions.sh`).

---

## Several instances sharing one root

Running more than two or three instances? See [Docker Reference:
Recommended layout for several instances](docker.md#recommended-layout-for-several-instances)
for organizing `INSTANCE_CONFIG_PATH`, `GITHUB_TOKEN_FILE`, and
`GLOBAL_CONFIG_PATH` under one `shared/` + `instances/` + `backups/` root,
independent of whichever pattern above each
individual instance follows.
