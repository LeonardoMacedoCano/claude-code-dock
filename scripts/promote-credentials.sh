#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
# shellcheck source=lib/config-path.sh
source "${SCRIPT_DIR}/lib/config-path.sh"

FORCE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║        claude-code-dock — Promote Credentials         ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

step() { echo -e "${CYAN}[→]${RESET} ${BOLD}$1${RESET}"; }
ok()   { echo -e "${GREEN}[✓]${RESET} $1"; }
warn() { echo -e "${YELLOW}[⚠]${RESET} $1"; }
fail() { echo -e "${RED}[✗]${RESET} $1" >&2; exit 1; }

SESSION_ARG=""
for arg in "$@"; do
    case "$arg" in
        --force|-f)
            FORCE=true
            ;;
        -h|--help)
            echo "Usage: $0 [session-name] [--force]"
            echo ""
            echo "  Copies THIS instance's own Claude Code login"
            echo "  (CONFIG_BASE_PATH/REMOTE_SESSION_NAME/.credentials.json, or"
            echo "  INSTANCE_CONFIG_PATH/.credentials.json if set) into"
            echo "  SHARED_CREDENTIALS_PATH, so other instances running"
            echo "  SHARED_CREDENTIALS_MODE=seed pick it up on their next boot."
            echo ""
            echo "  This is the explicit, operator-run promotion step for seed mode --"
            echo "  it does not run automatically, and it never touches other"
            echo "  instances' own config. See docs/docker.md#shared-credentials for"
            echo "  the difference between seed mode and the default live mode (which"
            echo "  syncs automatically and does not need this script)."
            echo ""
            echo "  session-name  Use .env.<session-name> instead of .env (matches"
            echo "                new-session.sh/session-up.sh's naming convention)."
            echo "  --force       Skip the confirmation prompt when the shared pool"
            echo "                already holds different credentials."
            exit 0
            ;;
        *)
            SESSION_ARG="$arg"
            ;;
    esac
done

header

if [ -n "${SESSION_ARG}" ]; then
    ENV_FILE="${PROJECT_DIR}/.env.${SESSION_ARG}"
    if [ ! -f "${ENV_FILE}" ]; then
        fail ".env.${SESSION_ARG} not found. Create it first with: ./scripts/new-session.sh ${SESSION_ARG}"
    fi
else
    ENV_FILE="${PROJECT_DIR}/.env"
    if [ ! -f "${ENV_FILE}" ]; then
        fail ".env not found. Pass a session name (./scripts/promote-credentials.sh <name>) or create .env first."
    fi
fi

step "Reading ${ENV_FILE##*/}..."

CONFIG_BASE_PATH="${CONFIG_BASE_PATH:-}"
REMOTE_SESSION_NAME="${REMOTE_SESSION_NAME:-}"
INSTANCE_CONFIG_PATH="${INSTANCE_CONFIG_PATH:-}"
SHARED_CREDENTIALS_PATH="${SHARED_CREDENTIALS_PATH:-}"

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

if ! resolve_config_dir; then
    fail "CONFIG_BASE_PATH/REMOTE_SESSION_NAME (or INSTANCE_CONFIG_PATH) not set in ${ENV_FILE##*/} -- cannot find this instance's config directory."
fi
ok "Instance config directory: ${CONFIG_DIR}"

if [ -z "${SHARED_CREDENTIALS_PATH}" ]; then
    fail "SHARED_CREDENTIALS_PATH is not set in ${ENV_FILE##*/}. Set it to the shared directory every instance should read the seed from, then re-run."
fi

CREDS_FILE="${CONFIG_DIR}/.credentials.json"

step "Checking this instance's own credentials..."

if [ -L "${CREDS_FILE}" ]; then
    fail "${CREDS_FILE} is a symlink, not a plain file -- this instance is running SHARED_CREDENTIALS_MODE=live (the default), which already syncs automatically. There is nothing to promote: live mode keeps SHARED_CREDENTIALS_PATH up to date on every login/refresh by itself. This script is only for SHARED_CREDENTIALS_MODE=seed instances."
fi

if [ ! -f "${CREDS_FILE}" ] || [ ! -s "${CREDS_FILE}" ]; then
    fail "No login found at ${CREDS_FILE}. Log in to this instance first (./scripts/attach.sh or ./scripts/remote.sh), then re-run this script."
fi

ok "Found this instance's own login: ${CREDS_FILE}"

SHARED_DIR="${SHARED_CREDENTIALS_PATH}"
if [[ "${SHARED_DIR}" == ./* ]]; then
    SHARED_DIR="${PROJECT_DIR}/${SHARED_DIR#./}"
fi
SHARED_FILE="${SHARED_DIR}/.credentials.json"

step "Checking the shared pool (${SHARED_DIR})..."

mkdir -p "${SHARED_DIR}"

if [ -s "${SHARED_FILE}" ] && ! cmp -s "${CREDS_FILE}" "${SHARED_FILE}"; then
    if [ "${FORCE}" != "true" ]; then
        warn "SHARED_CREDENTIALS_PATH already holds different credentials."
        echo ""
        echo -e "  ${RED}${BOLD}This will replace the seed every other SHARED_CREDENTIALS_MODE=seed${RESET}"
        echo -e "  ${RED}${BOLD}instance picks up on its NEXT restart. Already-running instances that${RESET}"
        echo -e "  ${RED}${BOLD}already seeded from the old value keep using it until they restart.${RESET}"
        echo ""
        read -r -p "  Continue? [y/N]: " CONFIRM
        if [[ "${CONFIRM,,}" != "y" ]]; then
            echo ""
            echo -e "  Cancelled."
            exit 0
        fi
    else
        warn "SHARED_CREDENTIALS_PATH already holds different credentials -- overwriting (--force)."
    fi
fi

cp "${CREDS_FILE}" "${SHARED_FILE}"
chmod 600 "${SHARED_FILE}"

ok "Promoted ${BOLD}${CONFIG_DIR}${RESET} into the shared pool."

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║              Credentials Promoted!                    ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Other instances with SHARED_CREDENTIALS_MODE=seed and no login of their"
echo -e "  own yet will pick this up on their ${BOLD}next start${RESET} (restart/recreate)."
echo -e "  This is a one-time copy, not a live sync -- re-run this script after a"
echo -e "  future re-login/refresh if you want the pool updated again."
echo ""
