#!/usr/bin/env bash

set -eo pipefail

# --- Root step-down (PUID/PGID) --------------------------------------------
# The image starts as root by default (see Dockerfile: no permanent USER
# directive) so this block can remap the built-in 'node' account to a
# different UID/GID before anything else runs -- LinuxServer.io-style, so a
# bind-mounted host directory owned by a non-1000 host user doesn't need a
# manual `chown -R 1000:1000`. This is the ONLY part of entrypoint.sh that
# ever runs as root, and it never writes into a bind mount -- only this
# container's own HOME directory entry, which lives in the image layer, not
# a mount point (the mounted subdirectories under it, like .claude, remain
# the operator's responsibility to chown on the host; see validate_config()
# below for the fatal() message that tells them so, now PUID/PGID-aware).
#
# setpriv (util-linux -- present in every Debian base image already, no
# extra package needed) is used instead of a fork-based su/runuser: it
# execve()s straight into the target command, leaving no wrapper process
# behind, which preserves the "the selected process is PID 1" guarantee this
# whole project is built around (see CLAUDE.md). --reuid/--regid set the
# real, effective, AND saved uid/gid together, so the dropped process cannot
# later regain root through the POSIX saved-set-user-ID backdoor
# (seteuid(0) succeeding because the saved uid was left at 0).
#
# After this exec, the script re-runs from the very top as the now-current
# (non-root) user -- `id -u` is no longer 0, so this whole block is skipped
# on that second pass and everything below behaves exactly as it did before
# PUID/PGID existed.
if [ "$(id -u)" = "0" ]; then
    PUID="${PUID:-1000}"
    PGID="${PGID:-1000}"
    FATAL_MARKER_FILE="${FATAL_MARKER_FILE:-/tmp/claude-dock-fatal}"

    if ! [[ "${PUID}" =~ ^[0-9]+$ ]] || ! [[ "${PGID}" =~ ^[0-9]+$ ]] || [ "${PUID}" = "0" ] || [ "${PGID}" = "0" ]; then
        echo "FATAL: PUID/PGID must be positive integers greater than 0 (got PUID=${PUID}, PGID=${PGID})." >&2
        echo "PUID/PGID=0 would run Claude Code as root, which Claude Code 2.x refuses under --dangerously-skip-permissions and which this project deliberately does not support." >&2
        echo "Set PUID/PGID to your host user's uid/gid (run 'id -u' / 'id -g' on the host) in .env instead." >&2
        touch "${FATAL_MARKER_FILE}" 2>/dev/null || true
        exec sleep infinity
    fi

    if [ "${PUID}" != "1000" ] || [ "${PGID}" != "1000" ]; then
        GROUPMOD_OK=true
        groupmod -o -g "${PGID}" node 2>&1 || GROUPMOD_OK=false
        USERMOD_OK=true
        usermod -o -u "${PUID}" node 2>&1 || USERMOD_OK=false

        if [ "${GROUPMOD_OK}" = "false" ] || [ "${USERMOD_OK}" = "false" ]; then
            echo "FATAL: could not remap the 'node' account to PUID=${PUID}/PGID=${PGID}." >&2
            touch "${FATAL_MARKER_FILE}" 2>/dev/null || true
            exec sleep infinity
        fi

        chown "${PUID}:${PGID}" "${HOME}" 2>/dev/null || true
    fi

    exec setpriv --reuid=node --regid=node --init-groups /bin/bash "$0" "$@"
fi
# --- end root step-down -----------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

print_banner() {
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "  ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗"
    echo " ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝"
    echo " ██║     ██║     ███████║██║   ██║██║  ██║█████╗  "
    echo " ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  "
    echo " ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗"
    echo "  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝"
    echo ""
    echo " ██████╗  ██████╗  ██████╗██╗  ██╗"
    echo " ██╔══██╗██╔═══██╗██╔════╝██║ ██╔╝"
    echo " ██║  ██║██║   ██║██║     █████╔╝ "
    echo " ██║  ██║██║   ██║██║     ██╔═██╗ "
    echo " ██████╔╝╚██████╔╝╚██████╗██║  ██╗"
    echo " ╚═════╝  ╚═════╝  ╚═════╝╚═╝  ╚═╝"
    echo -e "${RESET}"
    echo -e "${BOLD}  Claude Code — Persistent Environment for 24/7 Servers${RESET}"
    echo -e "  ${BLUE}https://github.com/LeonardoMacedoCano/claude-code-dock${RESET}"
    echo ""
    echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
}

LOG_DIR="${HOME}/.claude/logs"
LOG_FILE="${LOG_DIR}/dock.log"
LOG_MAX_LINES=2000
mkdir -p "${LOG_DIR}" 2>/dev/null || true

if [ -f "${LOG_FILE}" ] && [ "$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)" -gt "${LOG_MAX_LINES}" ]; then
    tail -n "${LOG_MAX_LINES}" "${LOG_FILE}" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "${LOG_FILE}"
fi

# Read by scripts/watchdog.sh (via `docker exec ... test -f`) to tell "fatal()
# fired this run" apart from a transient wedged tmux pane -- both report the
# same `unhealthy` status, but only one of them is fixable by a restart.
# Cleared unconditionally on every entrypoint run (including plain `docker
# restart`, which re-executes this script but keeps the container's writable
# layer, so a stale marker from a previous fatal() would otherwise survive
# into a run that never calls fatal() again).
FATAL_MARKER_FILE="${FATAL_MARKER_FILE:-/tmp/claude-dock-fatal}"
rm -f "${FATAL_MARKER_FILE}" 2>/dev/null || true

# Plain-text, ANSI-free copy of the setup steps below, persisted in the config
# volume. docker logs / the Unraid "Logs" tab only shows this cleanly until
# tmux takes over the tty; after that they render the raw terminal screen
# instead of scrolling log lines. This file stays readable regardless.
#
# The whole command is wrapped in `{ ...; } 2>/dev/null` rather than
# redirecting the printf's own stderr: when LOG_FILE's directory doesn't
# exist (e.g. config dir not writable yet), the failed `>>` open is a
# redirection error that bash reports on the *shell's* stderr before the
# command's own `2>/dev/null` would apply to it — it would otherwise leak
# a raw "No such file or directory" line into docker logs. Redirecting the
# whole group's stderr first (outer redirection, established before the
# body runs) suppresses that too.
log_write() {
    { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$(sed -E 's/(\x1b|\\033)\[[0-9;]*m//g' <<< "$2")" >> "${LOG_FILE}"; } 2>/dev/null || true
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_info()  { echo -e "  ${GREEN}[$(ts)] ✓${RESET} $1"; log_write "INFO"  "$1"; }
log_warn()  { echo -e "  ${YELLOW}[$(ts)] ⚠${RESET} $1"; log_write "WARN"  "$1"; }
log_error() { echo -e "  ${RED}[$(ts)] ✗${RESET} $1"; log_write "ERROR" "$1"; }
log_step()  { echo -e "  ${CYAN}[$(ts)] →${RESET} $1"; log_write "STEP"  "$1"; }

# Stops startup on unrecoverable misconfiguration. Deliberately does NOT
# `exit` — under `restart: unless-stopped`, exiting here just restarts the
# container in an endless loop that clears the terminal before the message
# can be read. Holding PID 1 on `sleep infinity` keeps the container "Up"
# (not "Restarting") with this error as the last thing in `docker logs`.
fatal() {
    local title="$1"
    local reason="$2"
    local fix="$3"

    echo ""
    echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "  ${RED}${BOLD}✗ FATAL: ${title}${RESET}"
    echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""
    echo -e "  ${reason}"
    echo ""
    echo -e "  ${BOLD}How to fix:${RESET}"
    echo -e "${fix}"
    echo ""
    echo -e "  The container stays up instead of restart-looping, so this message"
    echo -e "  stays visible in ${BOLD}docker logs${RESET}. After fixing it, run:"
    echo -e "    ${BOLD}docker compose up -d --force-recreate${RESET}"
    echo ""
    echo -e "  ${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo ""

    log_write "FATAL" "${title}: ${reason}"

    # See FATAL_MARKER_FILE definition above: tells scripts/watchdog.sh that
    # this container's `unhealthy` status is a persistent misconfiguration,
    # not a wedged process -- restarting it again would just reproduce the
    # same fatal() call instead of fixing anything.
    touch "${FATAL_MARKER_FILE}" 2>/dev/null || true

    exec sleep infinity
}

# Fails fast on misconfiguration that would otherwise surface as a silent,
# hard-to-diagnose restart loop: an unrecognized AUTO_START_MODE (a typo
# quietly falls through to interactive today, unnoticed) or a mounted
# directory the 'node' user (UID ${PUID:-1000}, remapped from the default
# 1000 by the root step-down block above when PUID/PGID are set) cannot
# write to (the #1 cause of crash loops — usually a bind-mounted host path
# owned by root because CONFIG_BASE_PATH/WORKSPACE_PATH was unset,
# misspelled, or never chown'd to match PUID/PGID).
validate_config() {
    local t0
    t0=$(date +%s)
    log_step "Validating configuration..."

    local mode="${AUTO_START_MODE:-interactive}"
    local target_uid="${PUID:-1000}"
    local target_gid="${PGID:-1000}"
    case "${mode}" in
        interactive|remote|shell) ;;
        *)
            fatal "Invalid AUTO_START_MODE" \
                "AUTO_START_MODE=\"${mode}\" is not a recognized execution mode." \
                "    Set AUTO_START_MODE to one of ${BOLD}interactive${RESET}, ${BOLD}remote${RESET}, ${BOLD}shell${RESET} in .env."
            ;;
    esac

    if ! mkdir -p "${HOME}/.claude" 2>/dev/null || \
       ! ( touch "${HOME}/.claude/.write_test" 2>/dev/null && rm -f "${HOME}/.claude/.write_test" 2>/dev/null ); then
        local config_owner
        config_owner=$(stat -c '%U:%G (uid=%u, gid=%g)' "${HOME}/.claude" 2>/dev/null || echo "unknown")
        local config_host_path="<your CONFIG_BASE_PATH>/${REMOTE_SESSION_NAME:-<session>}"
        [ -n "${CONFIG_BASE_PATH:-}" ] && [ -n "${REMOTE_SESSION_NAME:-}" ] && \
            config_host_path="${CONFIG_BASE_PATH}/${REMOTE_SESSION_NAME}"
        fatal "Config directory is not writable" \
            "/home/node/.claude (bind-mounted from CONFIG_BASE_PATH/REMOTE_SESSION_NAME on the host) is owned by ${BOLD}${config_owner}${RESET}, but this container runs as ${BOLD}node (uid=${target_uid}, gid=${target_gid})${RESET} and cannot write to it.\n\n  This almost always means the folder did not exist on the host yet, so Docker auto-created it as root the moment this container started." \
            "    Run this ON THE HOST (not inside the container), then restart:\n    ${BOLD}chown -R ${target_uid}:${target_gid} ${config_host_path}${RESET}\n    ${BOLD}docker compose up -d --force-recreate${RESET}\n\n    If CONFIG_BASE_PATH is not set in .env, set it first — otherwise it\n    silently falls back to ./configs, also created owned by root.\n    scripts/install.sh does this chown for you automatically on first setup (honoring PUID/PGID from .env if set)."
    fi

    if ! mkdir -p "${WORKSPACE_DIR:-/workspace}" 2>/dev/null || \
       ! ( touch "${WORKSPACE_DIR:-/workspace}/.write_test" 2>/dev/null && rm -f "${WORKSPACE_DIR:-/workspace}/.write_test" 2>/dev/null ); then
        local workspace_owner
        workspace_owner=$(stat -c '%U:%G (uid=%u, gid=%g)' "${WORKSPACE_DIR:-/workspace}" 2>/dev/null || echo "unknown")
        local workspace_host_path="${WORKSPACE_PATH:-<your WORKSPACE_PATH>}"
        fatal "Workspace directory is not writable" \
            "${WORKSPACE_DIR:-/workspace} (bind-mounted from WORKSPACE_PATH on the host) is owned by ${BOLD}${workspace_owner}${RESET}, but this container runs as ${BOLD}node (uid=${target_uid}, gid=${target_gid})${RESET} and cannot write to it." \
            "    Run this ON THE HOST (not inside the container), then restart:\n    ${BOLD}chown -R ${target_uid}:${target_gid} ${workspace_host_path}${RESET}\n    ${BOLD}docker compose up -d --force-recreate${RESET}"
    fi

    log_info "Configuration OK: mode=${mode}, config dir writable, workspace writable. (validated in $(( $(date +%s) - t0 ))s)"
}

# Wall-clock reference for the "Total startup time" line near the final
# exec -- lets the log show how long everything from here to the tmux/claude
# handoff actually took, instead of only per-line timestamps a reader would
# have to subtract by hand.
STARTUP_T0=$(date +%s)

log_write "STEP" "──── container start ────"

print_banner

log_step "Startup configuration:"
log_info "Execution mode:    ${BOLD}${AUTO_START_MODE:-interactive}${RESET}"
log_info "Auto-approve:      ${BOLD}${CLAUDE_AUTO_APPROVE:-false}${RESET}"
if [ "${CLAUDE_AUTO_APPROVE:-false}" = "true" ]; then
    log_warn "CLAUDE_AUTO_APPROVE=true: Claude runs commands with no per-command confirmation. Set a CPU/memory ceiling via docker-compose.resources.yml if this host has no other cap on it. See docs/security.md#credential-protection."
fi
log_info "Running as:        ${BOLD}$(id -un 2>/dev/null || echo node) (uid=${PUID:-1000}, gid=${PGID:-1000})${RESET}"
if [ -n "${REMOTE_SESSION_NAME:-}" ]; then
    log_info "Session ID:        ${BOLD}${REMOTE_SESSION_NAME}${RESET}"
else
    log_warn "REMOTE_SESSION_NAME is not set. Set it in .env to isolate this session."
fi
if [ -n "${CLAUDE_EXTRA_ARGS:-}" ]; then
    log_info "Extra arguments:   ${BOLD}${CLAUDE_EXTRA_ARGS}${RESET}"
fi
if [ -n "${TZ:-}" ]; then
    log_info "Timezone:          ${BOLD}${TZ}${RESET}"
fi
BUILD_SOURCE_FILE="${BUILD_SOURCE_FILE:-/etc/claude-dock-build-source}"
if [ -f "${BUILD_SOURCE_FILE}" ]; then
    BUILD_SOURCE_RAW="$(cat "${BUILD_SOURCE_FILE}" 2>/dev/null || echo "")"
    BUILD_SOURCE_KIND="${BUILD_SOURCE_RAW%%:*}"
    BUILD_SOURCE_REF="${BUILD_SOURCE_RAW#*:}"
    if [ "${BUILD_SOURCE_KIND}" = "local" ]; then
        log_info "Build source:      ${BOLD}local clone (CLAUDE_SOURCE_PATH=${BUILD_SOURCE_REF})${RESET}"
    else
        log_info "Build source:      ${BOLD}GitHub (ref: ${BUILD_SOURCE_REF})${RESET}"
    fi
fi
echo ""

log_step "Checking Claude Code installation..."
CLAUDE_CHECK_T0=$(date +%s)

if ! command -v claude &>/dev/null; then
    fatal "Claude Code binary missing" \
        "The 'claude' CLI was not found in PATH. The image may be corrupted, or the build did not finish." \
        "    ${BOLD}docker compose build --no-cache${RESET}\n    ${BOLD}docker compose up -d${RESET}"
fi

CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown version")
log_info "Claude Code: ${BOLD}${CLAUDE_VERSION}${RESET} (checked in $(( $(date +%s) - CLAUDE_CHECK_T0 ))s)"

validate_config

# ~/.claude.json lives outside the mounted volume and would be lost on restart.
# Symlinking it into the volume keeps credentials persistent across container restarts.
CLAUDE_JSON_REAL="${HOME}/.claude/.claude.json"
CLAUDE_JSON_LINK="${HOME}/.claude.json"

if [ ! -f "${CLAUDE_JSON_REAL}" ] && [ -d "${HOME}/.claude/backups" ]; then
    LATEST_BACKUP=$(ls -1t "${HOME}/.claude/backups/.claude.json.backup."* 2>/dev/null | head -1 || true)
    if [ -n "${LATEST_BACKUP}" ]; then
        cp "${LATEST_BACKUP}" "${CLAUDE_JSON_REAL}"
        log_info "Credentials restored from backup: $(basename "${LATEST_BACKUP}")"
    fi
fi

if [ -f "${CLAUDE_JSON_LINK}" ] && [ ! -L "${CLAUDE_JSON_LINK}" ]; then
    mv "${CLAUDE_JSON_LINK}" "${CLAUDE_JSON_REAL}"
    log_info ".claude.json moved into persistent volume"
fi

if [ ! -L "${CLAUDE_JSON_LINK}" ]; then
    ln -sf "${CLAUDE_JSON_REAL}" "${CLAUDE_JSON_LINK}"
fi

# Read below (near the final exec) to decide whether the "ACTION REQUIRED"
# block needs to tell the user a first login is still pending.
if [ -f "${CLAUDE_JSON_REAL}" ]; then
    HAS_CREDENTIALS=true
    log_info "Persistent login: ${BOLD}credentials loaded${RESET}"
else
    HAS_CREDENTIALS=false
    log_info "Persistent login: ${BOLD}waiting for first login${RESET}"
fi

if [ -n "${GIT_USER_NAME:-}" ]; then
    git config --global user.name "${GIT_USER_NAME}" 2>/dev/null && \
        log_info "Git user.name: ${GIT_USER_NAME}"
fi

if [ -n "${GIT_USER_EMAIL:-}" ]; then
    git config --global user.email "${GIT_USER_EMAIL}" 2>/dev/null && \
        log_info "Git user.email: ${GIT_USER_EMAIL}"
fi

# GITHUB_TOKEN_FILE is always this fixed in-container path by convention --
# docker-compose.yml mounts the HOST path from .env's GITHUB_TOKEN_FILE here
# (or /dev/null, read-only, when that's empty -- a standard Compose idiom for
# "optional file mount"). The token's actual value never has to sit in .env,
# a docker-compose environment: line, or the host shell's process environment
# -- only a host *path* does. Never echoed; only ever written straight into
# ~/.git-credentials (chmod 600).
GITHUB_TOKEN_FILE="${GITHUB_TOKEN_FILE:-/run/secrets/github_token}"

if [ -d "${GITHUB_TOKEN_FILE}" ]; then
    # Docker auto-creates an empty directory at a bind-mount target when the
    # HOST source path doesn't exist yet -- this is that misconfiguration,
    # not a real token file, so it needs a loud warning instead of silently
    # trying (and failing) to read it as a file.
    log_warn "GITHUB_TOKEN_FILE=${GITHUB_TOKEN_FILE} is a directory, not a file — the host path in .env's GITHUB_TOKEN_FILE probably doesn't exist yet. Create the file on the host and run: docker compose up -d --force-recreate"
elif [ -r "${GITHUB_TOKEN_FILE}" ]; then
    TOKEN_VALUE="$(tr -d '\n' < "${GITHUB_TOKEN_FILE}" 2>/dev/null || true)"
    if [ -n "${TOKEN_VALUE}" ]; then
        git config --global credential.helper store
        echo "https://x-access-token:${TOKEN_VALUE}@github.com" > "${HOME}/.git-credentials"
        chmod 600 "${HOME}/.git-credentials"
        log_info "GitHub token: configured (from GITHUB_TOKEN_FILE)"
    fi
fi

if [ -n "${GIT_REPO_URL:-}" ]; then
    WORKSPACE_EMPTY=$(find "${WORKSPACE_DIR:-/workspace}" -mindepth 1 -maxdepth 1 ! -name '.gitkeep' 2>/dev/null | head -1)
    if [ -z "${WORKSPACE_EMPTY}" ]; then
        log_step "Cloning repository into /workspace..."
        if git clone "${GIT_REPO_URL}" /workspace 2>&1 | while IFS= read -r line; do log_info "${line}"; done; then
            log_info "Repository cloned: ${GIT_REPO_URL}"
        else
            log_warn "Failed to clone repository: ${GIT_REPO_URL}"
        fi
    else
        log_info "GIT_REPO_URL set but /workspace is not empty — skipping clone."
    fi
fi

if [ "${CLAUDE_AUTO_APPROVE:-false}" = "true" ]; then
    SETTINGS_FILE="${HOME}/.claude/settings.json"
    if [ -f "${SETTINGS_FILE}" ]; then
        if command -v jq &>/dev/null; then
            UPDATED=$(jq '. + {"skipDangerousModePermissionPrompt": true}' "${SETTINGS_FILE}" 2>/dev/null)
            if [ -n "${UPDATED}" ]; then
                echo "${UPDATED}" > "${SETTINGS_FILE}"
                log_info "skipDangerousModePermissionPrompt enabled in settings.json"
            fi
        fi
    else
        echo '{"skipDangerousModePermissionPrompt":true}' > "${SETTINGS_FILE}"
        log_info "settings.json created with skipDangerousModePermissionPrompt=true"
    fi
fi

GLOBAL_DIR="${HOME}/.claude-global"

if [ -f "${GLOBAL_DIR}/CLAUDE.md" ]; then
    GLOBAL_MERGE_T0=$(date +%s)
    log_step "Applying global configuration..."

    LOCAL_MD="${HOME}/.claude/CLAUDE-local.md"
    GENERATED_MD="${HOME}/.claude/CLAUDE.md"

    if [ ! -f "${LOCAL_MD}" ] && [ -f "${GENERATED_MD}" ]; then
        if ! grep -q "^# GLOBAL CONFIG" "${GENERATED_MD}" 2>/dev/null; then
            mv "${GENERATED_MD}" "${LOCAL_MD}"
            log_info "Existing CLAUDE.md preserved as CLAUDE-local.md"
        fi
    fi

    {
        printf "# GLOBAL CONFIG — auto-generated at startup, do not edit\n\n"
        cat "${GLOBAL_DIR}/CLAUDE.md"
        if [ -f "${LOCAL_MD}" ]; then
            printf "\n---\n\n"
            cat "${LOCAL_MD}"
        fi
    } > "${GENERATED_MD}"

    log_info "Global CLAUDE.md applied (in $(( $(date +%s) - GLOBAL_MERGE_T0 ))s)"
fi

if [ -d "${GLOBAL_DIR}/commands" ]; then
    GLOBAL_CMDS=$(find "${GLOBAL_DIR}/commands" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l)
    if [ "${GLOBAL_CMDS}" -gt 0 ]; then
        mkdir -p "${HOME}/.claude/commands"
        for f in "${GLOBAL_DIR}/commands/"*.md; do
            [ -f "$f" ] && ln -sf "$f" "${HOME}/.claude/commands/$(basename "$f")"
        done
        log_info "Global commands: ${BOLD}${GLOBAL_CMDS} skill(s) linked${RESET}"
    fi
fi

if [ -d "${GLOBAL_DIR}/skills" ]; then
    GLOBAL_SKILLS=$(find "${GLOBAL_DIR}/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [ "${GLOBAL_SKILLS}" -gt 0 ]; then
        mkdir -p "${HOME}/.claude/skills"
        for d in "${GLOBAL_DIR}/skills/"*/; do
            [ -d "$d" ] && ln -sfn "${d%/}" "${HOME}/.claude/skills/$(basename "$d")"
        done
        log_info "Global skills: ${BOLD}${GLOBAL_SKILLS} skill(s) linked${RESET}"
    fi
fi

log_step "Workspace summary..."
WORKSPACE_FILES=$(ls "${WORKSPACE_DIR:-/workspace}" 2>/dev/null | wc -l)
log_info "Workspace: /workspace (${WORKSPACE_FILES} item(s))"

cd "${WORKSPACE_DIR:-/workspace}"

MODE="${AUTO_START_MODE:-interactive}"

CMD_BIN="claude"
CMD_ARGS=()

case "${MODE}" in
    remote)
        if [ "${CLAUDE_AUTO_APPROVE:-false}" = "true" ]; then
            CMD_ARGS+=("--dangerously-skip-permissions")
        fi
        # --continue reconnects to the Remote Control session recorded in the
        # most recent /workspace conversation instead of registering a brand
        # new one — without it, every container restart piles up another
        # dead entry with the same name in the claude.ai/code session list.
        # It can't be added unconditionally here: it hard-fails when this
        # workspace has no resumable conversation yet (e.g. a brand new
        # REMOTE_SESSION_NAME), which killed the tmux pane on first boot.
        # claude-remote-launch.sh below decides at runtime whether to try it
        # and falls back automatically if it fails immediately.
        if [ -n "${REMOTE_SESSION_NAME:-}" ]; then
            CMD_ARGS+=("--remote-control" "${REMOTE_SESSION_NAME}")
        else
            CMD_ARGS+=("--remote-control")
        fi
        ;;
    shell)
        CMD_BIN="bash"
        ;;
    interactive|*)
        if [ "${CLAUDE_AUTO_APPROVE:-false}" = "true" ]; then
            CMD_ARGS+=("--dangerously-skip-permissions")
        fi
        ;;
esac

if [ -n "${CLAUDE_EXTRA_ARGS:-}" ]; then
    # Quote-aware split without eval: xargs understands single/double quotes
    # for grouping (so `--append-system-prompt "be terse"` survives as one
    # argument) but, unlike eval, never expands $(...), `...`, ~, or globs --
    # a value that happens to contain shell metacharacters is only ever
    # passed through as literal text, never executed. `-n1` makes xargs
    # invoke `printf '%s\n'` once per parsed word, one per output line, which
    # mapfile below reassembles into the array. A non-zero xargs exit (e.g.
    # unmatched quote) falls back to plain whitespace splitting instead of
    # aborting startup.
    EXTRA_ARRAY=()
    EXTRA_SPLIT=""
    if EXTRA_SPLIT="$(printf '%s' "${CLAUDE_EXTRA_ARGS}" | xargs -n1 printf '%s\n' 2>/dev/null)"; then
        [ -n "${EXTRA_SPLIT}" ] && mapfile -t EXTRA_ARRAY <<< "${EXTRA_SPLIT}"
    else
        log_warn "CLAUDE_EXTRA_ARGS has unbalanced quotes — falling back to plain whitespace splitting."
        read -ra EXTRA_ARRAY <<< "${CLAUDE_EXTRA_ARGS}"
    fi
    CMD_ARGS+=("${EXTRA_ARRAY[@]}")
fi

if [ ${#CMD_ARGS[@]} -gt 0 ]; then
    DISPLAY_CMD="${CMD_BIN} ${CMD_ARGS[*]}"
else
    DISPLAY_CMD="${CMD_BIN}"
fi

# Remote mode routes through claude-remote-launch.sh instead of exec'ing
# claude directly, so it can try --continue and fall back without --continue
# if there's nothing resumable. DISPLAY_CMD above intentionally still shows
# the plain "claude ..." invocation — that's what actually ends up running.
LAUNCH_BIN="${CMD_BIN}"
if [ "${MODE}" = "remote" ]; then
    LAUNCH_BIN="/usr/local/bin/claude-remote-launch.sh"
fi

echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

RESOLVED_CONTAINER_NAME="${CONTAINER_NAME:-claude-code-dock}"
ATTACH_CMD="docker exec -it --user node ${RESOLVED_CONTAINER_NAME} tmux attach-session -t main"
SHELL_CMD="docker exec -it --user node ${RESOLVED_CONTAINER_NAME} bash"

# One line, always logged (unlike the case-specific echo block below), that
# ties mode + container name + session together -- so a reader of dock.log
# alone (no docker inspect needed) can answer "what is this container, and
# how do I reach it" without cross-referencing .env.
log_step "Startup summary"
log_info "Mode: ${BOLD}${MODE}${RESET} | Container: ${BOLD}${RESOLVED_CONTAINER_NAME}${RESET} | Session: ${BOLD}${REMOTE_SESSION_NAME:-<none>}${RESET}"
log_info "Total startup time: $(( $(date +%s) - STARTUP_T0 ))s"

case "${MODE}" in
    remote)
        echo -e "  ${BOLD}Execution mode:${RESET} ${GREEN}remote control${RESET}"
        echo -e "  ${BOLD}Connect:${RESET}        ${CYAN}${ATTACH_CMD}${RESET}"
        echo -e "  ${BOLD}Disconnect:${RESET}     ${CYAN}Ctrl+B${RESET} then ${CYAN}D${RESET}"
        echo -e "  ${BOLD}Resume:${RESET}         auto-continues the last conversation in /workspace if one exists;"
        echo -e "                     starts fresh automatically if there's nothing resumable"
        ;;
    shell)
        echo -e "  ${BOLD}Execution mode:${RESET} ${YELLOW}shell (bash)${RESET}"
        echo -e "  ${BOLD}Connect:${RESET}        ${CYAN}${SHELL_CMD}${RESET}"
        echo -e "  ${BOLD}Disconnect:${RESET}     ${CYAN}exit${RESET} or ${CYAN}Ctrl+D${RESET}"
        ;;
    *)
        echo -e "  ${BOLD}Execution mode:${RESET} ${GREEN}interactive${RESET}"
        echo -e "  ${BOLD}Connect:${RESET}        ${CYAN}${ATTACH_CMD}${RESET}"
        echo -e "  ${BOLD}Disconnect:${RESET}     ${CYAN}Ctrl+B${RESET} then ${CYAN}D${RESET}"
        echo -e "  ${BOLD}Debug shell:${RESET}    ${CYAN}${SHELL_CMD}${RESET}"
        ;;
esac

echo ""

# From here, tmux is about to take over the tty -- `docker logs`/Unraid's
# Logs tab stop showing scrolling text and start mirroring whatever is
# currently on the pane's screen instead (see LOG_FILE's own header comment
# above). This is the one place that has to say, in a way that survives into
# dock.log too, exactly what step this is and what to do next -- otherwise a
# reader watching docker logs after this point sees nothing new and has no
# way to tell "still starting" from "waiting on me to do something."
if [ "${MODE}" != "shell" ]; then
    if [ "${HAS_CREDENTIALS}" = "false" ]; then
        log_warn "ACTION REQUIRED: no Claude Code login found yet for session '${REMOTE_SESSION_NAME:-default}'. tmux is taking over the terminal now -- docker logs/Unraid's Logs tab will stop showing new text from this point on."
        log_warn "Next step: attach and complete the authentication prompt now: ${ATTACH_CMD}"
    elif [ "${MODE}" = "remote" ]; then
        log_info "Existing credentials found for '${REMOTE_SESSION_NAME:-default}' -- Remote Control will try to resume this session automatically (--continue)."
        log_info "If it does not appear on claude.ai/code within a minute, or needs re-pairing, attach and check the pane: ${ATTACH_CMD}"
    fi
    log_info "Live text log, unaffected by tmux taking the tty: ${LOG_FILE}"
fi

echo ""
log_info "Executing: ${BOLD}${DISPLAY_CMD}${RESET}"
echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

if [ "${MODE}" = "shell" ]; then
    exec "${CMD_BIN}" "${CMD_ARGS[@]}"
else
    exec tmux new-session -s main "${LAUNCH_BIN}" "${CMD_ARGS[@]}"
fi
