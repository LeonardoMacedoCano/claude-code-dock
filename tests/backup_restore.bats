#!/usr/bin/env bats

# Roundtrip coverage for backup.sh + restore.sh together: create data, back it
# up, simulate loss/corruption, restore, and assert the data actually comes
# back byte-for-byte. Existing tests cover retention on the backup side only
# -- none exercised restore.sh at all before this file.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"
RESTORE_SCRIPT="$PROJECT_ROOT/scripts/restore.sh"

SESSION="restore-test-session"

setup() {
  # Same rationale as backup_retention.bats: don't let this suite inherit
  # CONFIG_BASE_PATH/REMOTE_SESSION_NAME/WORKSPACE_PATH from whatever
  # environment happens to be running it.
  unset CONFIG_BASE_PATH REMOTE_SESSION_NAME WORKSPACE_PATH INSTANCE_CONFIG_PATH

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  mkdir -p "$TMP_PROJECT/configs/$SESSION"
  mkdir -p "$TMP_PROJECT/backups"

  echo '{"original":"credentials","marker":"roundtrip-test-value"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  printf 'CONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=%s\n' "$SESSION" > "$TMP_PROJECT/.env"

  # Copied into place (not run from PROJECT_ROOT directly) so PROJECT_DIR
  # inside each script resolves to TMP_PROJECT -- matching how
  # backup_retention.bats isolates itself. lib/ is copied alongside since
  # both scripts source scripts/lib/config-path.sh relative to SCRIPT_DIR.
  cp -r "$PROJECT_ROOT/scripts/lib" "$TMP_PROJECT/scripts/lib"
  cp "$BACKUP_SCRIPT" "$TMP_PROJECT/scripts/backup.sh"
  cp "$RESTORE_SCRIPT" "$TMP_PROJECT/scripts/restore.sh"

  export TMP_PROJECT
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_latest_archive() {
  ls -t "$TMP_PROJECT/backups/$SESSION"/claude-code-dock-${SESSION}-backup-*.tar.gz 2>/dev/null | head -1
}

@test "restore roundtrip: corrupted data is restored byte-for-byte from backup" {
  ORIGINAL_CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  # Simulate data loss/corruption on the live config dir.
  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  # restore.sh's only prompt in this path ("Confirm restore? ... [y/N]")
  # since the archive path is passed explicitly as $1.
  run bash -c "echo y | bash '$TMP_PROJECT/scripts/restore.sh' '$ARCHIVE'"
  [ "$status" -eq 0 ]

  RESTORED_CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"
  [ "$RESTORED_CONTENT" = "$ORIGINAL_CONTENT" ]
}

@test "restore roundtrip: pre-restore safety backup of the corrupted state is created" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash -c "echo y | bash '$TMP_PROJECT/scripts/restore.sh' '$ARCHIVE'"
  [ "$status" -eq 0 ]

  SAFETY_COUNT=$(ls "$TMP_PROJECT/backups/$SESSION"/claude-code-dock-${SESSION}-pre-restore-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
  [ "$SAFETY_COUNT" -eq 1 ]
}

@test "restore --dry-run leaves current data untouched" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash "$TMP_PROJECT/scripts/restore.sh" --dry-run "$ARCHIVE"
  [ "$status" -eq 0 ]

  CURRENT_CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"
  [ "$CURRENT_CONTENT" = '{"corrupted":"data"}' ]
}

@test "restore roundtrip: workspaces land back in PROJECT_DIR, not inside the config dir" {
  # CONFIG_BASE_PATH=./configs here resolves to $TMP_PROJECT/configs, a
  # subdirectory of PROJECT_DIR, not PROJECT_DIR itself -- the same shape as
  # the realistic CONFIG_BASE_PATH-outside-the-repo case. Before the
  # manifest fix, restoring an archive containing both the config dir and
  # ./workspaces/ extracted everything under dirname(CONFIG_DIR)
  # ($TMP_PROJECT/configs), silently placing workspaces at
  # $TMP_PROJECT/configs/workspaces instead of $TMP_PROJECT/workspaces.
  mkdir -p "$TMP_PROJECT/workspaces/myrepo"
  echo "important workspace file" > "$TMP_PROJECT/workspaces/myrepo/file.txt"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  rm -rf "$TMP_PROJECT/workspaces/myrepo"
  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash -c "echo y | bash '$TMP_PROJECT/scripts/restore.sh' '$ARCHIVE'"
  [ "$status" -eq 0 ]

  [ -f "$TMP_PROJECT/workspaces/myrepo/file.txt" ]
  [ "$(cat "$TMP_PROJECT/workspaces/myrepo/file.txt")" = "important workspace file" ]
  # Must not have leaked into the config directory's own tree.
  [ ! -d "$TMP_PROJECT/configs/workspaces" ]
}

@test "restore falls back to legacy single-destination extraction for pre-manifest archives" {
  # Archives created before the manifest mechanism existed carry no
  # .claude-code-dock-backup-manifest entry -- restore.sh must still handle
  # them via the old dirname(CONFIG_DIR) heuristic instead of failing.
  mkdir -p "$TEST_TMPDIR/legacy-archive-root/$SESSION"
  echo '{"legacy":"content"}' > "$TEST_TMPDIR/legacy-archive-root/$SESSION/settings.json"
  LEGACY_ARCHIVE="$TMP_PROJECT/backups/$SESSION/claude-code-dock-${SESSION}-backup-legacy.tar.gz"
  mkdir -p "$(dirname "$LEGACY_ARCHIVE")"
  tar -czf "$LEGACY_ARCHIVE" -C "$TEST_TMPDIR/legacy-archive-root" "$SESSION"

  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash -c "echo y | bash '$TMP_PROJECT/scripts/restore.sh' '$LEGACY_ARCHIVE'"
  [ "$status" -eq 0 ]

  RESTORED="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"
  [ "$RESTORED" = '{"legacy":"content"}' ]
}

@test "restore declining confirmation leaves current data untouched" {
  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  ARCHIVE="$(_latest_archive)"
  [ -n "$ARCHIVE" ]

  echo '{"corrupted":"data"}' > "$TMP_PROJECT/configs/$SESSION/settings.json"

  run bash -c "echo n | bash '$TMP_PROJECT/scripts/restore.sh' '$ARCHIVE'"
  [ "$status" -eq 0 ]

  CURRENT_CONTENT="$(cat "$TMP_PROJECT/configs/$SESSION/settings.json")"
  [ "$CURRENT_CONTENT" = '{"corrupted":"data"}' ]
}

