#!/usr/bin/env bash

# Shared helper: resolves this instance's persistent config directory
# (Claude Code credentials/settings/history). Source this after PROJECT_DIR
# is set and after CONFIG_BASE_PATH/REMOTE_SESSION_NAME/INSTANCE_CONFIG_PATH
# have been read from the process environment or .env.
#
# INSTANCE_CONFIG_PATH, when set, is used directly and wins over
# CONFIG_BASE_PATH/REMOTE_SESSION_NAME -- additive only: when it's unset,
# every caller resolves CONFIG_DIR exactly as it did before this variable
# existed. Consolidates the CONFIG_BASE_PATH/REMOTE_SESSION_NAME join (and
# its `./`-prefix normalization) that used to be copy-pasted, with subtly
# different edge-case handling per copy, across backup.sh/restore.sh/status.sh.
#
# Sets: CONFIG_DIR (and normalizes CONFIG_BASE_PATH in place, so callers
# that also use CONFIG_BASE_PATH directly afterward see the same
# already-normalized value).
# Returns 0 if CONFIG_DIR was resolved, 1 if neither INSTANCE_CONFIG_PATH
# nor a usable CONFIG_BASE_PATH+REMOTE_SESSION_NAME pair was available --
# callers apply their own fallback path and messaging in that case, since
# that part legitimately differs per script (backup.sh warns, restore.sh
# and status.sh don't).
resolve_config_dir() {
    if [ -n "${INSTANCE_CONFIG_PATH:-}" ]; then
        CONFIG_DIR="${INSTANCE_CONFIG_PATH}"
        if [[ "${CONFIG_DIR}" == ./* ]]; then
            CONFIG_DIR="${PROJECT_DIR}/${CONFIG_DIR#./}"
        fi
        return 0
    fi

    local base="${CONFIG_BASE_PATH:-}"
    if [[ "${base}" == ./* ]]; then
        base="${PROJECT_DIR}/${base#./}"
    fi
    CONFIG_BASE_PATH="${base}"

    if [ -n "${base}" ] && [ -n "${REMOTE_SESSION_NAME:-}" ]; then
        CONFIG_DIR="${base}/${REMOTE_SESSION_NAME}"
        return 0
    fi

    return 1
}
