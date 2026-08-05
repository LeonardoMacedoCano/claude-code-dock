# Proposal: Multi-Instance Architecture & Credential Model — PLANNING DOCUMENT

> **Status: DRAFT — under review. Not implemented. No runtime behavior changes.**
> This document is the Phase 0 + Phase 1 deliverable of a larger refactor (see
> [Phased Plan](#phased-plan)). It describes the current architecture in
> depth, proposes a target architecture, and lays out a phased path to get
> there — but this PR itself changes **no code**. `entrypoint.sh`,
> `docker-compose.yml`, and every script behave exactly as before. Do not
> build on top of the "Proposed" sections until they are explicitly approved
> and this status line is updated.

---

## 0. Why this document exists

claude-code-dock is used to run several independent, persistent Claude Code
instances on one host — one per project, personal workspace, or general-purpose
scratch area. The current architecture supports this (`new-session.sh` /
`session-up.sh` / `sessions.sh`, per-session `CONFIG_BASE_PATH/<name>`
isolation, opt-in `SHARED_CREDENTIALS_PATH`), but it grew incrementally and
has three concrete rough edges this proposal addresses:

1. **`SHARED_CREDENTIALS_PATH`'s live symlink + background poller** is
   fragile by construction (see [§2](#2-deep-dive-how-shared_credentials_path-actually-works-today))
   and was already patched once after a real incident where it silently
   failed to share a fresh login.
2. **The conceptual relationship between "shared infra" and "one instance's
   own state"** is implicit today — nothing stops an operator from pointing
   `SHARED_CREDENTIALS_PATH` at another session's own `CONFIG_BASE_PATH/<name>`
   directory, coupling one instance's lifecycle to another's.
3. **Backups are flat** (`./backups/*.tar.gz`, instance name only in the
   filename) rather than organized per instance.

Everything else the request asks about — GitHub token sharing, optional Git,
multiple workspace "types," the `shared/instances/backups` directory
shape — turns out to already be achievable today with **zero code changes**,
purely through how `.env` variables are set. Section 4 calls this out
explicitly, because it changes the actual size of this refactor a lot: the
real code-level surface is small and concentrated on the credential
mechanism and backup layout, not a rewrite.

---

## 1. Investigation Method

Read in full, not summarized from memory: `docker/entrypoint.sh`,
`docker-compose.yml`, `Dockerfile`, every `scripts/*.sh`, `.env.example`,
`docs/architecture.md`, `docs/security.md`, `docs/docker.md`,
`docs/git-integration.md`, `docs/getting-started.md`, `docs/unraid.md`,
`tests/*.sh`, `tests/*.bats` (in particular
`tests/entrypoint_shared_credentials.bats` and `tests/entrypoint_symlink.bats`,
which already characterize most of the current credential-sharing behavior
in an executable, CI-checked form). Cross-checked against the current
official Claude Code documentation for `CLAUDE_CONFIG_DIR` and credential
storage (see [§2.6](#26-official-claude-code-behavior-clau_config_dir)).

No code was changed to perform this investigation. All conclusions below are
traceable to a specific file/line or test.

---

## 2. Deep Dive: How `SHARED_CREDENTIALS_PATH` Actually Works Today

### 2.1 The mounts involved

`docker-compose.yml`:
```yaml
volumes:
  - ${WORKSPACE_PATH:-./workspaces}:/workspace
  - ${CONFIG_BASE_PATH:-./configs}/${REMOTE_SESSION_NAME:-default}:/home/node/.claude
  - ${GLOBAL_CONFIG_PATH:-/dev/null}:/home/node/.claude-global:ro
  - ${GITHUB_TOKEN_FILE:-/dev/null}:/run/secrets/github_token:ro
  - ${SHARED_CREDENTIALS_PATH:-/dev/null}:/home/node/.claude-shared-credentials
```

Two independent things live under `/home/node/.claude`:
- `/home/node/.claude` itself — the **entire** per-session config directory
  (credentials, `settings.json`, session/conversation history, `logs/`,
  `CLAUDE.md`). This is `CONFIG_BASE_PATH/<REMOTE_SESSION_NAME>`, always
  per-session, never shared.
- `/home/node/.claude-shared-credentials` — a **separate**, optional mount,
  only used to seed/sync one file: `.credentials.json`.

`SHARED_CREDENTIALS_PATH` never touches the rest of `~/.claude`. This is a
deliberate, already-correct design decision (see [§2.6](#26-official-claude-code-behavior-clau_config_dir)
for why widening it to the whole directory would be wrong).

### 2.2 What `entrypoint.sh` actually does, step by step

(`docker/entrypoint.sh` lines 298–456; the "Symlinked, not copied" comment
block right above line 326 and the poller's comment block at lines 383–432
are the canonical explanation — this section restates it precisely, not
speculatively.)

1. `SHARED_CREDS_DIR=/home/node/.claude-shared-credentials`,
   `SHARED_CREDS_FILE=$SHARED_CREDS_DIR/.credentials.json`,
   `SESSION_CREDS=/home/node/.claude/.credentials.json`.
2. **Gate:** `[ -d "$SHARED_CREDS_DIR" ]`. When `SHARED_CREDENTIALS_PATH` is
   unset, the mount resolves to `/dev/null` (a character special file, not a
   directory), so this is `false` and the entire block is a no-op — confirmed
   by `tests/entrypoint_shared_credentials.bats::"no shared credentials mount ... is a silent no-op"`.
3. **Writability check:** `touch`+`rm` a probe file in `SHARED_CREDS_DIR`.
   - **Not writable** (host dir doesn't exist yet and Docker auto-created it
     root-owned, or permissions changed after the fact): logs a warning and
     does **not** link. If `SESSION_CREDS` was already a symlink from a prior
     successful boot, it materializes a real local copy (`cp` through the
     link, then replace the link with that copy) so this session still works
     standalone this run. Non-fatal by design — unlike `validate_config()`'s
     checks on `CONFIG_BASE_PATH`/`WORKSPACE_PATH`, a broken shared-credentials
     mount must not block this instance's own login from working.
   - **Writable:** proceeds to step 4.
4. **Promotion, if `SESSION_CREDS` is a plain file** (a login predating
   `SHARED_CREDENTIALS_PATH`, or a fresh login from *this exact boot* if this
   is a restart after step 5/6 below already ran once): its content is copied
   into `SHARED_CREDS_FILE` (overwriting whatever was there, with a
   non-fatal warning first if the shared file held *different*, non-empty
   content), then the local file is removed.
5. **Link:** `ln -sf "$SHARED_CREDS_FILE" "$SESSION_CREDS"` — unconditional,
   whether the shared pool was just seeded, already had content, or is still
   empty.
6. **Live-sync poller**, started as a backgrounded subshell (`&`; `disown`)
   that survives the final `exec tmux ...` (`exec` replaces the script's
   process image but keeps already-forked children):
   ```
   loop forever:
     sleep 5s (SHARED_CREDS_POLL_INTERVAL, test-only override)
     if SESSION_CREDS is a regular file again (not a symlink) and non-empty:
       cp it into SHARED_CREDS_FILE
       rm SESSION_CREDS
       ln -sf SHARED_CREDS_FILE SESSION_CREDS
       log it
   ```

### 2.3 Why the poller exists at all — the root mechanism

A plain symlink is enough **only** for writes that open the existing path
and truncate it in place (`O_TRUNC`) — e.g. a shell redirection
(`echo ... > $SESSION_CREDS`), confirmed by
`tests/entrypoint_shared_credentials.bats::"an in-place write ... goes straight through the symlink"`.

`claude` does not write `.credentials.json` that way. A login or an OAuth
token refresh writes a **new file** and `rename()`s it over the old path.
`rename()` replaces whatever directory entry was at that path — including a
symlink — with the new file, exactly as it would replace any other file
there. The symlink is not "followed and then truncated"; it is atomically
detached and discarded, and a fresh regular file (owned by this session's own
directory, invisible to `SHARED_CREDENTIALS_PATH`) is left in its place.

This was not a hypothetical risk found during this investigation — it is a
confirmed, already-fixed incident (see `CLAUDE.md`'s entrypoint.sh rule 10,
and the git history: `fix/shared-credentials-live-symlink`, merged as PR #6
in this repo's own log). The first shipped version of `SHARED_CREDENTIALS_PATH`
used a symlink with **no poller**, and a real login left the shared pool
completely empty because the write never went through the link at all. The
poller (§2.2 step 6) is the fix, not the original design.

`tests/entrypoint_shared_credentials.bats::"a login that replaces the path
outright (rename-over-target, like claude does) ..."` reproduces this exact
failure mode with a real (unmocked) `sleep` and asserts the poller recovers
within a bounded number of iterations.

### 2.4 Answering the 19 requested scenarios directly

| # | Scenario | Confirmed behavior (code + tests) |
|---|----------|-------------------------------------|
| 1 | docker-compose.yml mount shape | §2.1 — dedicated directory mount, `/dev/null` fallback idiom, **not** `:ro` (unlike `GITHUB_TOKEN_FILE`/`GLOBAL_CONFIG_PATH`) since `entrypoint.sh` writes through it |
| 2 | entrypoint.sh logic | §2.2, `entrypoint.sh:298-456` |
| 3 | Related scripts | `scripts/backup.sh` dereferences the symlink before taring (§2.5); no other script touches this path |
| 4 | Dockerfile | No involvement — mount-only feature, nothing baked into the image |
| 5 | Volumes/mounts | §2.1 |
| 6 | `/home/node/.claude` config | Untouched by this feature except for the one file `.credentials.json` inside it |
| 7 | `~/.claude.json` | A **separate** mechanism (`CLAUDE_JSON_REAL`/`CLAUDE_JSON_LINK`, `entrypoint.sh:276-296`) — always per-session, symlinked from outside the volume into it, never shared. Confirms `SHARED_CREDENTIALS_PATH` only ever touches `.credentials.json`, not `.claude.json` |
| 8 | Symlink usage | §2.2 steps 4-5 |
| 9 | Credential polling | §2.2 step 6, §2.3 |
| 10 | Copy logic | §2.2 step 4 (promotion) and step 6 (re-promotion after a live write) |
| 11 | First authentication | If `SHARED_CREDS_FILE` starts empty: session links to it empty, logs in normally through the link (in-place `O_TRUNC` writes go straight through per §2.3 — but `claude`'s actual login write is a `rename()`, so in practice the poller is what catches it, within ~5s), then the poller promotes+relinks. Log line: `"pool currently empty -- waiting for first login"` |
| 12 | Refresh/re-auth | Same `rename()`-over-target path as first login — same poller mechanism catches it, same ~5s window |
| 13 | Two+ instances running simultaneously | Both link to the same `SHARED_CREDS_FILE`. Each has its **own independent poller**. No cross-instance coordination beyond the shared file itself |
| 14 | Two instances updating near-simultaneously | **Not covered by any existing test.** Analysis: last-writer-wins, no locking (`cp` is not atomic w.r.t. a concurrent `cp` from another instance's poller). A worst case — both pollers detect a local rename() within the same ~5s tick and both `cp` at nearly the same wall-clock moment — could interleave, though `cp` of a small JSON file is fast enough in practice that a byte-level interleave is unlikely; the realistic risk is **not** file corruption but **one instance's still-valid refresh token silently overwriting another's newer one**, which the next refresh cycle on the losing instance would then be attempting against a token the server may have already rotated past. This is exactly the kind of race the credential-seed proposal in §5 is designed to avoid by not having a continuously-live shared master file in the first place |
| 15 | After container restart | Symlink is gone (mount is fresh, but the *target* file persists on the host); re-established by steps 2-5 every boot; no poller runs during the gap, but nothing writes during a restart either |
| 16 | After container recreate | Identical to restart — nothing here is keyed to container identity, only to the host paths |
| 17 | Shared file doesn't exist yet | `SHARED_CREDS_DIR` still exists (mount always creates it), but `SHARED_CREDS_FILE` doesn't — session links to a symlink pointing at a not-yet-existing target; `claude` sees no credentials, prompts login normally |
| 18 | Old local `.credentials.json` already exists | §2.2 step 4 — promoted into the shared pool (with a warning if it differs from what's already there), not silently discarded |
| 19 | Auth invalidated/re-authenticated | Same as #12 — a fresh login after invalidation is, mechanically, just another `rename()`-over-target write; same poller path |

### 2.5 Backup interaction

`scripts/backup.sh::create_backup_archive()` detects when
`$CONFIG_DIR/.credentials.json` is a symlink and stages a copy of the whole
config dir with **only that one file** dereferenced into a real file before
taring — otherwise `tar` (no `-h`/`--dereference` passed) would store the
symlink's target path as text, producing a backup with no actual login in
it. Every other symlink under the config dir (global commands/skills from
`GLOBAL_CONFIG_PATH`) is deliberately left as a symlink, since those
regenerate from source on every boot. This part of the mechanism is correct
today and needs no change regardless of what §5 concludes.

### 2.6 Official Claude Code behavior: `CLAUDE_CONFIG_DIR`

Per Claude Code's own documentation (code.claude.com/docs/en/env-vars) and
corroborating community sources: `CLAUDE_CONFIG_DIR` does not scope to
credentials — it **redirects the entire `~/.claude` directory**: settings,
`.credentials.json`, `CLAUDE.md`, project-scoped state, everything. Its
documented use case is isolated *profiles* ("run Claude Code as a different
account"), not sharing a login across otherwise-independent working
directories.

This confirms the current design's choice — a dedicated, narrowly-scoped
`SHARED_CREDENTIALS_PATH` mount plus a symlink for one specific file — is
**more correct** than pointing `CLAUDE_CONFIG_DIR` at a shared directory
would be. Doing the latter across N instances would merge their entire
config: conversation history, `settings.json`, and project state would
collide or overwrite each other, not just share a login. **This proposal
does not recommend adopting `CLAUDE_CONFIG_DIR` for sharing, and no phase
below introduces it.** (Two GitHub issues — anthropics/claude-code#3833 and
#25762 — also suggest `CLAUDE_CONFIG_DIR`'s edge-case behavior has shifted
across Claude Code releases; treat any specific claim about it as
version-dependent and re-verify against whatever Claude Code version is
running before relying on it further.)

---

## 3. What Must Not Break (compiled from the investigation above)

- Every session's `settings.json`, conversation history, and `CLAUDE.md`
  stay isolated per `CONFIG_BASE_PATH/<REMOTE_SESSION_NAME>` — no proposal
  below widens sharing beyond `.credentials.json`.
- `GIT_REPO_URL`, `GITHUB_TOKEN_FILE`, `GIT_USER_NAME`, `GIT_USER_EMAIL` stay
  fully optional, exactly as today — no instance is assumed to be a Git
  repository.
- `CONFIG_BASE_PATH`/`REMOTE_SESSION_NAME`/`WORKSPACE_PATH`/`CONTAINER_NAME`
  keep working unmodified for anyone who doesn't opt into anything new —
  see the [compatibility matrix](#6-compatibility-matrix).
- `entrypoint.sh` must always end in `exec tmux new-session ...` / `exec
  bash` (project invariant, unrelated to this refactor but binding on any
  change to the file).
- `scripts/backup.sh`'s symlink-dereferencing behavior for
  `.credentials.json` (§2.5) must be preserved or explicitly superseded, not
  silently dropped.
- The existing `tests/entrypoint_shared_credentials.bats` /
  `entrypoint_symlink.bats` suites are the closest thing this project has to
  an executable spec for current behavior — any Phase 3 change needs an
  updated or superseding suite, not a deleted one, so a regression is
  visible.

---

## 4. Already Achievable Today, Zero Code Changes

Before proposing new mechanisms, it's worth being explicit about how much of
the requested directory shape is just a matter of **which values go into
existing variables** — this materially shrinks the actual code-change
surface in §7.

**The `shared/` + `instances/` tree.** Nothing prevents an operator today
from choosing:
```
CONFIG_BASE_PATH=/mnt/user/prod-apps/claude-code-dock/instances
SHARED_CREDENTIALS_PATH=/mnt/user/prod-apps/claude-code-dock/shared/claude-login
```
which produces, on the host, exactly:
```
claude-code-dock/
├── shared/
│   └── claude-login/
│       └── .credentials.json
└── instances/
    ├── jornada/            <- CONFIG_BASE_PATH/<REMOTE_SESSION_NAME>
    │   └── .claude.json, settings.json, logs/, ...
    ├── pipehero/
    └── homo/
```
This is purely a documentation gap today (`.env.example`,
`docs/getting-started.md`, `docs/unraid.md` all show `configs/<session>`
flat under the project root as the example, not this shape) — not a missing
feature.

**Shared vs. per-instance GitHub token.** `GITHUB_TOKEN_FILE` is already a
per-session `.env` value pointing at an arbitrary host path. Pointing every
session's `.env` at the same file (`shared/github/github_token.txt`) or at
different files (`instances/<name>/github_token.txt`) are **both already
fully supported**, today, with no code change — it's a choice the operator
already has and this proposal only needs to document both patterns.

**"Workspace types" (git / local / multi).** `WORKSPACE_PATH`,
`GIT_REPO_URL`, and `GITHUB_TOKEN_FILE` are already three independently
optional variables. A "git" instance is just one with `GIT_REPO_URL` set; a
"local" instance is one without it; a "multi" instance is just a
`WORKSPACE_PATH` that happens to contain several project subfolders — Claude
Code itself has no opinion on that, and neither does claude-code-dock.
Introducing a `WORKSPACE_TYPE` variable would have **no functional effect
anywhere in `entrypoint.sh`** — nothing would branch on it — so per the
project's own Scope Discipline checklist (`CLAUDE.md`) and the request's own
instruction not to overengineer, **this proposal recommends against adding
`WORKSPACE_TYPE` as a variable** and instead treats it as a pure
documentation concept: three worked examples in a new "Usage Patterns" doc
(§8).

**Net effect:** the genuinely new code-level work is concentrated on three
things — the credential mechanism (§5), backup layout (§5.4), and one
optional new variable for path explicitness (§5.3). Everything else in the
original request is a documentation deliverable.

---

## 5. Proposed Architecture

### 5.1 Directory tree (conceptual, documentation-level)

```
<root>/                                   operator-chosen, e.g. /mnt/user/prod-apps/claude-code-dock
├── shared/
│   ├── claude-login/
│   │   └── .credentials.json             seed file (see 5.2) — NOT a live master store
│   └── github/
│       └── github_token.txt              optional, only if sharing one GitHub token across instances
│
├── instances/
│   ├── jornada/                          == CONFIG_BASE_PATH/<REMOTE_SESSION_NAME> today
│   │   └── (settings.json, .claude.json, .credentials.json, logs/, ...)
│   ├── pipehero/
│   └── homo/
│
└── backups/
    ├── jornada/                          NEW in this proposal -- see 5.4 (flat today)
    ├── pipehero/
    └── homo/
```

Workspaces (`WORKSPACE_PATH`) are **not** part of this tree and are never
moved into it — they stay wherever the operator's actual project files live
today (`/mnt/user/prod-apps/<project>`, `/mnt/user/workspace/...`, etc.),
exactly as the request insists. This tree is purely the Dock's own
state/config/backup root, distinct from any project's own working
directory.

### 5.2 Credential model: seed, not live master store

**Rejected: keep the current live symlink + poller as the primary/default
mechanism.** It works (§2 confirms it, and the incident that motivated the
poller is already fixed), but it has two structural properties this
proposal treats as disqualifying for a *default*, going forward:
1. A perpetual background process per instance, for the instance's entire
   lifetime, whose only job is polling for a rename() (Scope Discipline:
   "no new steady-state failure mode" — this is exactly that kind of thing,
   already flagged as a concern in `CLAUDE.md`'s own architecture notes).
2. An un-analyzed multi-instance write race (§2.4 #14) with no locking,
   where "last writer wins" on a live, shared, continuously-refreshed
   credential file is a genuine risk once more than one instance is
   authenticated and refreshing tokens concurrently against the same shared
   file — not merely a theoretical edge case.

**Proposed default: one-time credential seeding, explicit promotion.**

```
FIRST INSTANCE, NO SHARED SEED YET
  instance starts -> shared/claude-login/.credentials.json absent
  -> claude prompts login (in this instance's own, isolated .claude/ dir)
  -> operator runs an explicit "promote" action (script or documented
     command) to copy this instance's .credentials.json into
     shared/claude-login/.credentials.json
     (NOT automatic -- see rationale below)

NEXT INSTANCE
  instance starts -> shared/claude-login/.credentials.json exists
  -> entrypoint.sh copies it (a real file, not a symlink) into this
     instance's own .claude/.credentials.json, ONLY if this instance has
     no credentials of its own yet
  -> claude starts already authenticated
  -> from this point on, this instance's copy is independent -- claude's
     own rename()-based writes work completely normally against a plain
     file in this instance's own directory. No symlink, nothing to
     intercept, nothing to poll.
```

This eliminates the entire class of problem in §2.3 by construction: there
is no symlink for `rename()` to detach, because there is no live link at
all after the initial copy. It also eliminates the §2.4 #14 race, because
there is no continuously-shared file multiple live processes write to —
only a one-time read at startup.

**Why "explicit promotion," not automatic, for the write side:** the
current mechanism promotes automatically and silently keeps promoting on
every detected local write, which is exactly the property that creates the
race in §2.4 #14. Making promotion an explicit, operator-initiated action
(a `scripts/promote-credentials.sh <instance>`-style command, to be
designed in Phase 3, not this PR) means only one instance's login is ever
the seed at a given time, and it changes only when a human decides it
should — not automatically on every token refresh across every instance
simultaneously.

**Open question this proposal cannot resolve from documentation alone —
flagged explicitly per the request's own instruction not to guess:** does
Claude Code's OAuth refresh-token rotation invalidate an old refresh token
once a newer one has been issued and used elsewhere? If yes, then an
instance seeded from a stale copy of `shared/claude-login/.credentials.json`
(one that has since been refreshed by whichever instance is actually using
it day-to-day) could fail to refresh once its local copy's refresh token is
no longer accepted, forcing a fresh login on that instance despite having
been "seeded." Neither this repository nor Claude Code's public
documentation states this explicitly. **This is precisely the kind of thing
the requester asked to validate in practice before any production code
changes** — Phase 3 (§9) proposes a concrete, minimal test: seed two real
instances from one login, let both run for a period spanning at least one
natural token refresh, and observe whether both remain authenticated. Until
that's run, treat the seed model's long-run behavior as unverified, not
assumed-safe.

**Fallback if the seed model doesn't hold up in practice:** keep today's
live symlink + poller mechanism available, unchanged, as an explicit opt-in
(e.g. a `SHARED_CREDENTIALS_MODE=live` value) for operators who have
validated it works for their usage pattern and accept the trade-offs in
§2.4 #14 — do not remove working functionality without a proven
replacement. This is a compatibility commitment, not a hedge: see §6.

### 5.3 `INSTANCE_ID` / `INSTANCE_CONFIG_PATH` — evaluated, partially adopted

**`INSTANCE_ID` replacing `REMOTE_SESSION_NAME`: not recommended.** They
would be the same concept under a new name — `REMOTE_SESSION_NAME` already
is the stable identity used to derive the config subdirectory, the backup
filename prefix, and the default `CONTAINER_NAME` suffix
(`.env.example:30-34`, `new-session.sh:75-86`). Renaming it breaks every
existing script, doc, and running installation's `.env` for a naming
preference with no functional gain — exactly what the request's own rule 15
("no cosmetic changes without functional benefit") warns against. **Not
adopted.**

A separate, purely-cosmetic **`DISPLAY_NAME`** (optional, shown only in the
startup banner/log, e.g. `DISPLAY_NAME=Jornada da Liberdade` alongside
`REMOTE_SESSION_NAME=jornada`) is a small, real, additive convenience if
desired — but it's optional polish, not part of this refactor's critical
path, and should not block the rest of this plan.

**`INSTANCE_CONFIG_PATH`: recommended as an additive, optional override —
not a replacement.** The genuine gap is explicitness: today, the actual
config path is always an implicit join of two variables
(`CONFIG_BASE_PATH/REMOTE_SESSION_NAME`), computed identically in five
different scripts (`entrypoint.sh` via the compose mount,
`backup.sh`/`restore.sh`/`status.sh`/`new-session.sh`, each with their own
copy of the same `if [ -n CONFIG_BASE_PATH ] && [ -n REMOTE_SESSION_NAME ]`
logic). Proposal: an optional `INSTANCE_CONFIG_PATH` that, when set, is
used directly as the mount source (winning over
`CONFIG_BASE_PATH`+`REMOTE_SESSION_NAME`); when unset, every script computes
it exactly as today. This is fully backward compatible — nobody who doesn't
set it sees any difference — and gives operators who want the explicit
`instances/<name>/claude` shape from §5.1 a documented way to say so
directly instead of relying on the implicit join always producing it.
Implementation detail (path resolution precedence, and updating the
duplicated join logic in five scripts into one shared computation) is Phase
2 work, not this PR.

### 5.4 Backups: per-instance subfolder

**Recommended, small, real change.** Today, `scripts/backup.sh` writes
`./backups/claude-code-dock-<session>-backup-<timestamp>.tar.gz` — flat,
with the instance name only in the filename. Proposal: when
`REMOTE_SESSION_NAME` (or `INSTANCE_CONFIG_PATH`, see §5.3) is set, write
into `./backups/<session>/claude-code-dock-<session>-backup-<timestamp>.tar.gz`
instead. `BACKUP_RETENTION` continues to apply per subfolder (i.e.,
per-instance, exactly as today — retention already globs on the
session-specific filename pattern, `manage_old_backups()`, so scoping the
directory doesn't change the counting logic, only where the files land).
`restore.sh --list` needs to glob one level deeper.
**Backward-compat note:** existing flat backups in `./backups/*.tar.gz`
must still be listable/restorable after this change — `restore.sh` should
check both the new per-instance path and the legacy flat path rather than
silently orphaning existing backups (§6).

**Explicitly confirmed already correct, no change needed:** what the backup
does and does not include. `CONFIG_BASE_PATH/REMOTE_SESSION_NAME` (always),
`./workspaces/` (if non-empty), external `WORKSPACE_PATH` (only with
`--include-workspace`, off by default — deliberately not redundant with
whatever external backup already covers a large workspace, per the
request's own instruction). This should be stated more prominently in
`docs/docker.md`'s Backups section (documentation-only change).

### 5.5 Security analysis

- **Credential exposure surface**: the seed model (§5.2) narrows, not
  widens, the current exposure — no instance's live, continuously-refreshed
  credential file is ever mounted into more than one container
  simultaneously; only a one-time copy crosses the boundary, and only via
  an explicit promotion action.
- **Cross-instance access**: nothing in this proposal grants one instance
  filesystem access to another's `instances/<name>/` directory — each
  remains its own bind mount, exactly as today. `shared/` stays the only
  intentionally-crossed boundary, and only for the two things explicitly
  opted into (`claude-login/`, `github/`).
- **Arbitrary/overly-broad `WORKSPACE_PATH`**: the request asks about
  validating this. Recommendation: **do not** add filesystem sandboxing or
  path allowlisting — this would be a new, complex, easy-to-get-wrong
  security mechanism duplicating what the host's own permissions already
  do, and risks breaking legitimate Unraid setups (array paths, NFS
  mounts, `/mnt/user/...` conventions already documented across
  `docs/unraid.md`) for marginal benefit against a threat model this
  project already scopes to "single trusted host/user"
  (`docs/security.md#threat-model`). This matches the request's own
  instruction: reduce *accidental* misconfiguration, not build an
  artificial sandbox. The one concrete, low-risk improvement worth doing:
  `validate_config()` already fails loudly on an unwritable config/workspace
  dir — extending that same fail-fast pattern to a **non-existent**
  `INSTANCE_CONFIG_PATH` (§5.3) target with a clear message is in scope for
  Phase 2; a bespoke path-traversal/allowlist validator is not.
- **`shared/github/github_token.txt`**: identical trust boundary to today's
  single-instance `GITHUB_TOKEN_FILE` (docs/security.md's existing
  analysis already covers this fully) — sharing it across instances widens
  blast radius exactly the same way `SHARED_CREDENTIALS_PATH` already does
  for Claude credentials (`docs/security.md`'s existing §"Never share the
  config directory" note already states this principle generally; it just
  needs a parallel note added for the GitHub-token case in Phase 4).

---

## 6. Compatibility Matrix

| Variable | Current use | Proposed replacement | Compatible? | Deprecated? | Removal planned? |
|---|---|---|---|---|---|
| `CONFIG_BASE_PATH` | Base dir + `REMOTE_SESSION_NAME` join → config mount source | Stays; `INSTANCE_CONFIG_PATH` becomes an optional override that wins when set | Yes — fully unchanged when `INSTANCE_CONFIG_PATH` unset | No | No |
| `REMOTE_SESSION_NAME` | Identity: config subdir, backup prefix, default container name | Stays as-is (§5.3 — `INSTANCE_ID` rename rejected) | Yes | No | No |
| `SHARED_CREDENTIALS_PATH` | Live symlink+poller target dir | Becomes the seed source dir (§5.2) under the new default mode; existing live-sync behavior preserved under an explicit legacy mode | Yes, but **behavior** changes under the new default — needs a clear migration note, not just a variable rename | Mechanism (live mode), not the variable | Only if, after Phase 3 validation, the live mode is judged unsafe enough to sunset — not decided in this document |
| `GLOBAL_CONFIG_PATH` | Global `CLAUDE.md`/`commands/`/`skills/` mount | Unchanged | Yes | No | No |
| `CLAUDE_SOURCE_PATH` | Local build source | Unchanged | Yes | No | No |
| `WORKSPACE_PATH` | Project files mount | Unchanged | Yes | No | No |
| `GITHUB_TOKEN_FILE` | Host path to token file | Unchanged; `shared/github/...` vs `instances/<name>/...` is just a choice of value (§4) | Yes | No | No |
| `CONTAINER_NAME` | Explicit or derived-by-scripts container name | Unchanged | Yes | No | No |
| `AUTO_START_MODE` | interactive/remote/shell | Unchanged | Yes | No | No |
| `BACKUP_RETENTION` | Backups kept per session | Unchanged in meaning; applies per-subfolder after §5.4 | Yes | No | No |
| *(new)* `INSTANCE_CONFIG_PATH` | — | Optional explicit override of the `CONFIG_BASE_PATH`+`REMOTE_SESSION_NAME` join | N/A (additive) | N/A | N/A |
| *(new)* `SHARED_CREDENTIALS_MODE` | — | `seed` (new default) or `live` (today's mechanism, opt-in) | N/A (additive) | N/A | N/A |
| *(rejected)* `INSTANCE_ID` | — | — | — | — | Not introduced |
| *(rejected)* `WORKSPACE_TYPE` | — | — | — | — | Not introduced (documentation-only, §4) |

No existing variable is removed or silently reinterpreted by this proposal.
The one behavior-level change that isn't purely additive is
`SHARED_CREDENTIALS_PATH`'s default *mode* (live → seed) — called out
explicitly above and requiring its own migration note (§10) precisely
because "same variable, different runtime behavior" is the riskiest kind of
change to ship quietly.

---

## 7. Documentation Plan

New/changed docs (all Phase 1, i.e. content only, still true even after
approval — actual variable/behavior changes ship alongside their own phase):

1. **New: `docs/usage-patterns.md`** — the three worked examples from the
   request (Git-versioned project, local/no-Git workspace, multi-project
   workspace), generic, no personal-project names. Explains an instance can
   represent a project, an environment, a personal workspace, or a
   multi-project scratch area — never assumes Git.
2. **New: this document**, kept up to date through each phase, superseded by
   a final "Architecture v2" write-up once Phase 6 ships, at which point
   its content folds into `docs/architecture.md` and this file is archived
   (not deleted — historical record of the decision).
3. **`docs/architecture.md`**: add the responsibility-layer diagram from the
   request —
   `Remote Control → Claude Code → claude-code-dock → Docker → Host/Unraid`
   — with one paragraph per layer's responsibility, and an explicit
   sentence that the Dock does not attempt to replace Remote Control (this
   is implicit today; the request wants it explicit).
4. **`docs/docker.md`**: update the "claude-code-dock volumes" and
   "Multiple Instances" sections once §5 ships, plus the backup-scope
   clarification from §5.4.
5. **`.env.example`**: add `INSTANCE_CONFIG_PATH` and
   `SHARED_CREDENTIALS_MODE` in their own grouped, opt-in section once
   Phase 2/3 ship — not in this PR.
6. **`docs/unraid.md`** + `unraid/claude-code-dock.xml`: update the
   recommended directory structure example to the `shared/instances/backups`
   shape from §5.1, and add the two new template fields once they exist.

---

## 8. Phased Plan

**Phase 0 — Investigation.** Done; this document is its output.

**Phase 1 — Documentation & Plan (this PR).** This document,
`docs/usage-patterns.md`, and no other file changes beyond what's listed in
§9 (tests). **Stop and wait for approval before Phase 2.**

**Phase 2 — Config path refactor** (post-approval): introduce
`INSTANCE_CONFIG_PATH` as an additive override (§5.3); consolidate the
duplicated `CONFIG_BASE_PATH`+`REMOTE_SESSION_NAME` join logic (currently
copy-pasted across `backup.sh`/`restore.sh`/`status.sh`/`new-session.sh`)
into one sourced helper; update `docker-compose.yml`, examples, docs.

**Phase 3 — Credential model** (post-approval, post-Phase-2, and only after
the practical validation in §5.2's open question has actually been run):
implement the seed model as `SHARED_CREDENTIALS_MODE=seed` (new default for
*new* setups only — see §10 for existing-install handling), keep
`SHARED_CREDENTIALS_MODE=live` as the exact current mechanism, unchanged,
for anyone who opts into it. New/updated bats coverage per §9.

**Phase 4 — GitHub.** Mostly documentation (§4 already shows the mechanism
needs no code change) — add the `shared/github/` vs. per-instance pattern
to `docs/git-integration.md`, add explicit "no GitHub configured" /
"no Git repo" validation notes confirming today's actual silent-no-op
behavior is intentional and documented, not accidental.

**Phase 5 — Backups.** `backups/<instance>/` subfolder (§5.4),
backward-compatible `restore.sh --list`, updated retention tests.

**Phase 6 — Migration.** Documented, operator-run procedure (§10) for
moving an existing flat `configs/<session>` install into the
`instances/<session>` shape and/or opting into
`SHARED_CREDENTIALS_MODE=seed` — never automatic, never destructive of the
old layout until the operator explicitly removes it.

Each phase after 1 ships as its own PR, gated on the previous phase's tests
passing and, for Phase 3 specifically, on the practical multi-instance
credential-refresh validation actually being run and its result recorded in
this document before implementation starts.

---

## 9. Testing Strategy

### 9.1 Already covered by the existing suite (no new work needed)

`tests/entrypoint_shared_credentials.bats` (10 cases) and
`tests/entrypoint_symlink.bats` already exercise scenarios 1, 2, 3(partial),
6, 7, 9, 10, 11(partial), 12, 17, 18 from the request's list of 20 — see the
mapping in §2.4's table, which cites the exact test name for each. These
stay as the regression baseline through Phase 3; Phase 3 must not delete
them, only add a parallel suite for the new `seed` mode and adjust the
existing suite's scope to `SHARED_CREDENTIALS_MODE=live` explicitly once
that becomes an explicit opt-in rather than the only mode.

### 9.2 Gap identified during this investigation, addressed in this PR

Scenario 14 (two instances updating credentials near-simultaneously) has
**no existing test** — §2.4 flags this as an analyzed-but-unverified risk
in the *current* live mode. This PR adds one new, non-behavior-changing
characterization test (`tests/entrypoint_shared_credentials_race.bats`) that
documents this gap under current behavior: two backgrounded promotions
racing to write `SHARED_CREDS_FILE` produce a last-write-wins result with no
corruption and no lock — a baseline for comparison once Phase 3's seed model
(which structurally removes this race, §5.2) ships.

### 9.3 Planned for later phases (not implemented in this PR)

| # | Scenario | Phase | Notes |
|---|---|---|---|
| 4 | Second instance uses existing shared credential | 3 | Seed-mode equivalent of existing live-mode test |
| 5 | Third instance | 3 | Same pattern, confirms N-way, not just 2-way |
| 8 | Restart | 3 | Seed persists in instance's own dir regardless of shared pool state |
| 13 | Two instances simultaneous (seed mode) | 3 | No poller to race — should be trivially safe; test asserts this |
| 15 | Manual promotion command | 3 | New script, needs its own coverage once designed |
| 20 | Invalid `INSTANCE_CONFIG_PATH` (e.g. unwritable, or a file not a dir) | 2 | Parallel to existing `validate_config()` tests for `CONFIG_BASE_PATH` |
| — | Real, unmocked Claude Code login + token refresh across two seeded instances | 3, **manual, not automatable** | This is the open question in §5.2 — requires an actual Anthropic account and real wall-clock time spanning a token refresh; document the procedure and its result here once run, do not attempt to script fake OAuth flows |

---

## 10. Migration Strategy

No automatic migration in this PR or in any phase without a preceding
explicit `docs/`-documented procedure. Shape, for Phase 6:

1. Identify current layout (`CONFIG_BASE_PATH` value, list of
   `REMOTE_SESSION_NAME`s from `sessions.sh`/`.env.*` files present).
2. Create the new `shared/` + `instances/` structure alongside the old one
   (does not touch old data).
3. Copy (not move) each session's config dir into `instances/<name>/`.
4. Validate: start a **test** container pointed at the copied path,
   confirm Remote Control connects, confirm the existing login still works,
   confirm the workspace (unmoved, per §5.1) still mounts correctly, confirm
   Git config/push still work if applicable, confirm a restart preserves
   state.
5. Only after that validation passes, manually repoint the real `.env`
   (`CONFIG_BASE_PATH=.../instances`, or `INSTANCE_CONFIG_PATH=...`) and
   recreate the real container.
6. Old data at the pre-migration path is left in place, untouched, for the
   operator to remove manually once satisfied — never auto-deleted by any
   script this project ships.

## 11. Rollback Strategy

Because migration never deletes the old layout (§10 step 6), rollback is:
point `.env` back at the old `CONFIG_BASE_PATH`/`SHARED_CREDENTIALS_PATH`
values and `docker compose up -d --force-recreate`. For
`SHARED_CREDENTIALS_MODE`, rollback from `seed` to `live` is just changing
the variable back — the live mechanism is preserved unchanged (§6), not
replaced, so this is always available as an escape hatch through at least
one full major version after Phase 3 ships.

---

## 12. Risks

- **Unverified refresh-token behavior across seeded instances** (§5.2) is
  the single largest risk in this whole proposal — Phase 3 must not start
  implementation before the manual validation in §9.3's last row is run.
- **`SHARED_CREDENTIALS_PATH`'s behavior change (live default → seed
  default) is the one non-purely-additive change** in this plan — an
  operator who upgrades without reading the migration note could see
  different sync behavior than they're used to. Mitigation: Phase 3 ships
  with `SHARED_CREDENTIALS_MODE` unset defaulting to `live` for **existing**
  installs detected via presence of the old poller's log lines in
  `dock.log`, `seed` only for fresh installs — exact detection mechanism to
  be finalized during Phase 3 design, not assumed here.
- **Five scripts duplicating the same path-join logic** (§5.3) is a
  pre-existing maintenance risk this proposal reduces but Phase 2 must be
  careful not to introduce subtle divergence between the consolidated
  helper and any one script's current edge-case handling (e.g. `./`-prefix
  normalization, which currently appears slightly differently in
  `backup.sh` vs `restore.sh`).
- **Backup subfolder migration (§5.4)** risks silently orphaning existing
  flat backups if `restore.sh --list` isn't updated to check both
  locations — explicitly called out as a requirement, not an afterthought.

---

## 13. Acceptance Criteria

Restated from the request, unchanged, as the target for the *whole*
initiative (not this PR alone): multiple instances coexist with independent
state; Claude authentication is reusable without manual per-instance login;
the mechanism doesn't depend on a fragile symlink; no unnecessary continuous
polling; GitHub stays optional; local and multi-project workspaces work
without Git; Remote Control keeps working; restart/recreate preserve state;
backup/restore work; credentials aren't accidentally exposed; documentation
matches real behavior; existing installs have a migration path; rollback is
documented.

---

## 14. Explicitly Rejected / Out of Scope

- `WORKSPACE_TYPE` as a variable (§4) — no functional effect, documentation
  only.
- `INSTANCE_ID` renaming `REMOTE_SESSION_NAME` (§5.3) — cosmetic, breaks
  compatibility for no gain.
- `CLAUDE_CONFIG_DIR` as a shared-credentials mechanism (§2.6) — relocates
  the whole config, not just credentials; would merge unrelated instances'
  state.
- Filesystem sandboxing / path allowlisting for `WORKSPACE_PATH` (§5.5) —
  duplicates host permissions, risks breaking legitimate Unraid setups,
  outside this project's stated threat model.
- A web UI, an orchestrator, or anything that competes with or wraps
  Remote Control — unchanged from the project's existing Scope Discipline;
  nothing in this proposal touches that boundary.
- Automatic, unattended data migration — Phase 6 is always operator-run and
  non-destructive of the prior layout.

---

## 15. Open Questions for the Requester

1. Confirm the credential-seed model (§5.2) as the direction to validate in
   practice before Phase 3 implementation — or prefer keeping live-sync as
   the only/default mechanism, accepting the analyzed race (§2.4 #14) and
   the steady-state poller?
2. Who runs the real multi-instance token-refresh validation (§9.3 last
   row), and on what timeline — this blocks Phase 3 start.
3. `INSTANCE_CONFIG_PATH` (§5.3) — approved as additive-only, or should it
   fully replace `CONFIG_BASE_PATH`+`REMOTE_SESSION_NAME` in new docs/examples
   going forward (while keeping the old variables working)?
4. Backups (§5.4) — confirm `backups/<instance>/` subfolder with
   backward-compatible flat-path fallback in `restore.sh`, or a different
   shape?
5. Any objection to the `shared/github/github_token.txt` pattern being
   documented as a first-class option (§4), given it widens blast radius
   the same way `SHARED_CREDENTIALS_PATH` already does today?
