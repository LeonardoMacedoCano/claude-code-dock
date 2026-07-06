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
log_write() {
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$(sed -E 's/(\x1b|\\033)\[[0-9;]*m//g' <<< "$2")" >> "${LOG_FILE}" 2>/dev/null || true
}

log_info()  { echo -e "  ${GREEN}✓${RESET} $1"; log_write "INFO"  "$1"; }
log_warn()  { echo -e "  ${YELLOW}⚠${RESET} $1"; log_write "WARN"  "$1"; }
log_error() { echo -e "  ${RED}✗${RESET} $1"; log_write "ERROR" "$1"; }
log_step()  { echo -e "  ${CYAN}→${RESET} $1"; log_write "STEP"  "$1"; }

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
echo ""

log_step "Checking Claude Code installation..."

if ! command -v claude &>/dev/null; then
    log_error "Claude Code not found in PATH."
    log_error "Rebuild the image: docker compose build --no-cache"
    exit 1
fi

CLAUDE_VERSION=$(claude --version 2>/dev/null || echo "unknown version")
log_info "Claude Code: ${BOLD}${CLAUDE_VERSION}${RESET}"

log_step "Preparing environment..."
mkdir -p "${HOME}/.claude" "${WORKSPACE_DIR:-/workspace}"
log_info "Directories verified."

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

log_step "Validating workspace..."

if [ -d "${WORKSPACE_DIR:-/workspace}" ] && [ -r "${WORKSPACE_DIR:-/workspace}" ]; then
    WORKSPACE_FILES=$(ls "${WORKSPACE_DIR:-/workspace}" 2>/dev/null | wc -l)
    log_info "Workspace: /workspace (${WORKSPACE_FILES} item(s))"
else
    log_warn "/workspace not accessible. Check WORKSPACE_PATH in .env"
fi

cd "${WORKSPACE_DIR:-/workspace}"

MODE="${AUTO_START_MODE:-interactive}"

CMD_BIN="claude"
CMD_ARGS=()

case "${MODE}" in
    remote)
        if [ "${CLAUDE_AUTO_APPROVE:-true}" = "true" ]; then
            CMD_ARGS+=("--dangerously-skip-permissions")
        fi
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

echo ""
echo -e "  ${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""

case "${MODE}" in
    remote)
        echo -e "  ${BOLD}Execution mode:${RESET} ${GREEN}remote control${RESET}"
        echo -e "  ${BOLD}Connect:${RESET}        ${CYAN}docker exec -it claude-code-dock tmux attach-session -t main${RESET}"
        echo -e "  ${BOLD}Disconnect:${RESET}     ${CYAN}Ctrl+B${RESET} then ${CYAN}D${RESET}"
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
        echo -e "  Credentials saved in ${CYAN}./config/${RESET} and persist across restarts."
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
    exec tmux new-session -s main "${CMD_BIN}" "${CMD_ARGS[@]}"
fi
