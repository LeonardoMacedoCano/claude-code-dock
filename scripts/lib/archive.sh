#!/usr/bin/env bash

# Shared helper: backup.sh (and restore.sh's own pre-restore safety backup)
# can archive multiple top-level entries that came from DIFFERENT source
# directories in the same .tar.gz -- the session config (rooted at
# dirname(CONFIG_DIR)), the local ./workspaces/ (rooted at PROJECT_DIR), and
# optionally an external --include-workspace directory (rooted at its own
# dirname). `tar -c` supports this fine via one `-C <dir> <name>` pair per
# entry, but a single `tar -x -C <target>` on restore cannot reproduce it --
# there is only one destination directory for the whole extraction. Without
# this manifest, restore.sh had to guess a single destination (dirname of
# the config dir), which is only correct when CONFIG_BASE_PATH/
# INSTANCE_CONFIG_PATH happens to equal PROJECT_DIR -- otherwise workspaces
# silently landed inside the config directory instead of at PROJECT_DIR.
#
# The fix: record, at archive time, which destination directory each
# top-level entry needs to be extracted back into, and ship that mapping
# inside the same archive. restore.sh then extracts each entry individually
# into its own recorded destination instead of assuming one shared root.
#
# Archives created before this existed have no manifest -- restore.sh falls
# back to the old single-destination heuristic for those, so previously
# taken backups stay restorable exactly as before (correct whenever they
# only ever contained the config dir, which is the common case that made
# the bug go unnoticed).

ARCHIVE_MANIFEST_NAME=".claude-code-dock-backup-manifest"
ARCHIVE_MANIFEST_TMPDIR=""
ARCHIVE_MANIFEST_FILE=""

# Call once, after deciding an archive is actually going to be created (i.e.
# after any "nothing to back up" early exit), before adding entries.
archive_manifest_init() {
    ARCHIVE_MANIFEST_TMPDIR="$(mktemp -d)"
    ARCHIVE_MANIFEST_FILE="${ARCHIVE_MANIFEST_TMPDIR}/${ARCHIVE_MANIFEST_NAME}"
    : > "${ARCHIVE_MANIFEST_FILE}"
}

# Records that the top-level archive entry "$1" (the same name passed to tar
# as the path argument) must be extracted back into destination dir "$2".
# Call this once per `tar_cmd+=("-C" ... ...)` pair added by the caller.
archive_manifest_add() {
    printf '%s\t%s\n' "$1" "$2" >> "${ARCHIVE_MANIFEST_FILE}"
}

# Frees the temp dir created by archive_manifest_init. Safe to call even if
# init was never called (e.g. the caller exited early with nothing to back
# up) -- ARCHIVE_MANIFEST_TMPDIR stays empty in that case.
archive_manifest_cleanup() {
    [ -n "${ARCHIVE_MANIFEST_TMPDIR}" ] && rm -rf "${ARCHIVE_MANIFEST_TMPDIR}"
    ARCHIVE_MANIFEST_TMPDIR=""
    ARCHIVE_MANIFEST_FILE=""
}

# restore.sh side: extracts every top-level entry to the destination
# recorded for it in the manifest, instead of one shared -C target. Returns
# 1 (with nothing extracted) if the manifest is missing or empty, so the
# caller can fall back to the legacy single-destination behavior.
archive_extract_with_manifest() {
    local tarfile="$1"
    local manifest_content
    manifest_content="$(tar -xzf "${tarfile}" -O "${ARCHIVE_MANIFEST_NAME}" 2>/dev/null || true)"

    [ -z "${manifest_content}" ] && return 1

    local name dest
    while IFS=$'\t' read -r name dest; do
        [ -z "${name}" ] && continue
        mkdir -p "${dest}"
        tar -xzf "${tarfile}" -C "${dest}" "${name}"
    done <<< "${manifest_content}"

    return 0
}
