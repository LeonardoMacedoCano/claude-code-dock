#!/usr/bin/env bash

set -eo pipefail

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

    exec sleep infinity
}

# Fails fast on misconfiguration that would otherwise surface as a silent,
# hard-to-diagnose restart loop: an unrecognized AUTO_START_MODE (a typo
# quietly falls through to interactive today, unnoticed) or a mounted
# directory the 'node' user (UID 1000) cannot write to (the #1 cause of
# crash loops — usually a bind-mounted host path owned by root because
# CONFIG_BASE_PATH/WORKSPACE_PATH was unset, misspelled, or never chown'd).
validate_config() {
    log_step "Validating configuration..."

    local mode="${AUTO_START_MODE:-interactive}"
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
            "/home/node/.claude (bind-mounted from CONFIG_BASE_PATH/REMOTE_SESSION_NAME on the host) is owned by ${BOLD}${config_owner}${RESET}, but this container runs as ${BOLD}node (uid=1000, gid=1000)${RESET} and cannot write to it.\n\n  This almost always means the folder did not exist on the host yet, so Docker auto-created it as root the moment this container started." \
            "    Run this ON THE HOST (not inside the container), then restart:\n    ${BOLD}chown -R 1000:1000 ${config_host_path}${RESET}\n    ${BOLD}docker compose up -d --force-recreate${RESET}\n\n    If CONFIG_BASE_PATH is not set in .env, set it first — otherwise it\n    silently falls back to ./configs, also created owned by root.\n    scripts/install.sh does this chown for you automatically on first setup."
    fi

    if ! mkdir -p "${WORKSPACE_DIR:-/workspace}" 2>/dev/null || \
       ! ( touch "${WORKSPACE_DIR:-/workspace}/.write_test" 2>/dev/null && rm -f "${WORKSPACE_DIR:-/workspace}/.write_test" 2>/dev/null ); then
        local workspace_owner
        workspace_owner=$(stat -c '%U:%G (uid=%u, gid=%g)' "${WORKSPACE_DIR:-/workspace}" 2>/dev/null || echo "unknown")
        local workspace_host_path="${WORKSPACE_PATH:-<your WORKSPACE_PATH>}"
        fatal "Workspace directory is not writable" \
            "${WORKSPACE_DIR:-/workspace} (bind-mounted from WORKSPACE_PATH on the host) is owned by ${BOLD}${workspace_owner}${RESET}, but this container runs as ${BOLD}node (uid=1000, gid=1000)${RESET} and cannot write to it." \
            "    Run this ON THE HOST (not inside the container), then restart:\n    ${BOLD}chown -R 1000:1000 ${workspace_host_path}${RESET}\n    ${BOLD}docker compose up -d --force-recreate${RESET}"
    fi

    log_info "Configuration OK: mode=${mode}, config dir writable, workspace writable."
}

log_write "STEP" "──── container start ────"

print_banner

log_step "Startup configuration:"
log_info "Execution mode:    ${BOLD}${AUTO_START_MODE:-interactive}${RESET}"
log_info "Auto-approve:      ${BOLD}${CLAUDE_AUTO_APPROVE:-true}${RESET}"
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

if ! command -v claude &>/dev/null; then
    fatal "Claude Code binary missing" \
        "The 'claude' CLI was not found in PATH. The image may be corrupted, or the build did not finish." \
        "    ${BOLD}docker compose build --no-cache${RESET}\n    ${BOLD}docker compose up -d${RESET}"
fi

CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown version")
log_info "Claude Code: ${BOLD}${CLAUDE_VERSION}${RESET}"

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

if [ -f "${CLAUDE_JSON_REAL}" ]; then
    log_info "Persistent login: ${BOLD}credentials loaded${RESET}"
else
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

if [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global credential.helper store
    echo "https://x-access-token:${GITHUB_TOKEN}@github.com" > "${HOME}/.git-credentials"
    chmod 600 "${HOME}/.git-credentials"
    log_info "GitHub token: configured"
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

if [ "${CLAUDE_AUTO_APPROVE:-true}" = "true" ]; then
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

SHARED_DIR="${HOME}/.claude-shared"

if [ -f "${SHARED_DIR}/CLAUDE.md" ]; then
    log_step "Applying shared configuration..."

    LOCAL_MD="${HOME}/.claude/CLAUDE-local.md"
    GENERATED_MD="${HOME}/.claude/CLAUDE.md"

    if [ ! -f "${LOCAL_MD}" ] && [ -f "${GENERATED_MD}" ]; then
        if ! grep -q "^# SHARED CONFIG" "${GENERATED_MD}" 2>/dev/null; then
            mv "${GENERATED_MD}" "${LOCAL_MD}"
            log_info "Existing CLAUDE.md preserved as CLAUDE-local.md"
        fi
    fi

    {
        printf "# SHARED CONFIG — auto-generated at startup, do not edit\n\n"
        cat "${SHARED_DIR}/CLAUDE.md"
        if [ -f "${LOCAL_MD}" ]; then
            printf "\n---\n\n"
            cat "${LOCAL_MD}"
        fi
    } > "${GENERATED_MD}"

    log_info "Shared CLAUDE.md applied"
fi

if [ -d "${SHARED_DIR}/commands" ]; then
    SHARED_CMDS=$(find "${SHARED_DIR}/commands" -maxdepth 1 -name "*.md" 2>/dev/null | wc -l)
    if [ "${SHARED_CMDS}" -gt 0 ]; then
        mkdir -p "${HOME}/.claude/commands"
        for f in "${SHARED_DIR}/commands/"*.md; do
            [ -f "$f" ] && ln -sf "$f" "${HOME}/.claude/commands/$(basename "$f")"
        done
        log_info "Shared commands: ${BOLD}${SHARED_CMDS} skill(s) linked${RESET}"
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
        if [ "${CLAUDE_AUTO_APPROVE:-true}" = "true" ]; then
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
        if [ "${CLAUDE_AUTO_APPROVE:-true}" = "true" ]; then
            CMD_ARGS+=("--dangerously-skip-permissions")
        fi
        ;;
esac

if [ -n "${CLAUDE_EXTRA_ARGS:-}" ]; then
    read -ra EXTRA_ARRAY <<< "${CLAUDE_EXTRA_ARGS}"
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

case "${MODE}" in
    remote)
        echo -e "  ${BOLD}Execution mode:${RESET} ${GREEN}remote control${RESET}"
        echo -e "  ${BOLD}Connect:${RESET}        ${CYAN}docker exec -it claude-code-dock tmux attach-session -t main${RESET}"
        echo -e "  ${BOLD}Disconnect:${RESET}     ${CYAN}Ctrl+B${RESET} then ${CYAN}D${RESET}"
        echo -e "  ${BOLD}Resume:${RESET}         auto-continues the last conversation in /workspace if one exists;"
        echo -e "                     starts fresh automatically if there's nothing resumable"
        ;;
    shell)
        echo -e "  ${BOLD}Execution mode:${RESET} ${YELLOW}shell (bash)${RESET}"
        echo -e "  ${BOLD}Connect:${RESET}        ${CYAN}docker exec -it claude-code-dock bash${RESET}"
        echo -e "  ${BOLD}Disconnect:${RESET}     ${CYAN}exit${RESET} or ${CYAN}Ctrl+D${RESET}"
        ;;
    *)
        echo -e "  ${BOLD}Execution mode:${RESET} ${GREEN}interactive${RESET}"
        echo -e "  ${BOLD}Connect:${RESET}        ${CYAN}docker exec -it claude-code-dock tmux attach-session -t main${RESET}"
        echo -e "  ${BOLD}Disconnect:${RESET}     ${CYAN}Ctrl+B${RESET} then ${CYAN}D${RESET}"
        echo -e "  ${BOLD}Debug shell:${RESET}    ${CYAN}./scripts/shell.sh${RESET}"
        echo ""
        echo -e "  ${BOLD}First use:${RESET} Claude Code will prompt for authentication."
        echo -e "  Credentials saved in ${CYAN}CONFIG_BASE_PATH/REMOTE_SESSION_NAME${RESET} and persist across restarts."
        ;;
esac

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
