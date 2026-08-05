#!/usr/bin/env bats

# Covers INSTANCE_CONFIG_PATH: an additive, optional override that wins over
# CONFIG_BASE_PATH/REMOTE_SESSION_NAME wherever a script resolves this
# instance's persistent config directory. Unset, every script must resolve
# CONFIG_DIR exactly as before this variable existed -- the pre-existing
# suites (backup_retention.bats, backup_restore.bats, status_update_check.bats)
# already cover that case and must keep passing unmodified.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
BACKUP_SCRIPT="$PROJECT_ROOT/scripts/backup.sh"
RESTORE_SCRIPT="$PROJECT_ROOT/scripts/restore.sh"
STATUS_SCRIPT="$PROJECT_ROOT/scripts/status.sh"
NEW_SESSION_SCRIPT="$PROJECT_ROOT/scripts/new-session.sh"

setup() {
  unset CONFIG_BASE_PATH REMOTE_SESSION_NAME WORKSPACE_PATH INSTANCE_CONFIG_PATH

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  cp -r "$PROJECT_ROOT/scripts/lib" "$TMP_PROJECT/scripts/lib"
  cp "$BACKUP_SCRIPT" "$TMP_PROJECT/scripts/backup.sh"
  cp "$RESTORE_SCRIPT" "$TMP_PROJECT/scripts/restore.sh"
  cp "$STATUS_SCRIPT" "$TMP_PROJECT/scripts/status.sh"
  cp "$NEW_SESSION_SCRIPT" "$TMP_PROJECT/scripts/new-session.sh"

  mkdir -p "$TMP_PROJECT/backups"

  export TMP_PROJECT
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "backup.sh: INSTANCE_CONFIG_PATH wins over CONFIG_BASE_PATH+REMOTE_SESSION_NAME" {
  EXPLICIT_DIR="$TEST_TMPDIR/instances/jornada/claude"
  mkdir -p "$EXPLICIT_DIR"
  echo '{"marker":"instance-config-path-content"}' > "$EXPLICIT_DIR/settings.json"

  # A decoy at the CONFIG_BASE_PATH+REMOTE_SESSION_NAME location -- must NOT
  # end up in the archive, proving the override actually took effect instead
  # of both paths accidentally resolving to the same content.
  mkdir -p "$TMP_PROJECT/configs/jornada"
  echo '{"marker":"should-not-be-backed-up"}' > "$TMP_PROJECT/configs/jornada/settings.json"

  printf 'CONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=jornada\nINSTANCE_CONFIG_PATH=%s\n' "$EXPLICIT_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]

  ARCHIVE="$(ls "$TMP_PROJECT/backups/jornada"/claude-code-dock-jornada-backup-*.tar.gz)"
  [ -f "$ARCHIVE" ]

  mkdir -p "$TEST_TMPDIR/extracted-actual"
  tar -xzf "$ARCHIVE" -C "$TEST_TMPDIR/extracted-actual"

  CONTENT="$(cat "$TEST_TMPDIR/extracted-actual/claude/settings.json")"
  [ "$CONTENT" = '{"marker":"instance-config-path-content"}' ]
}

@test "status.sh: reports the INSTANCE_CONFIG_PATH directory, not CONFIG_BASE_PATH/REMOTE_SESSION_NAME, when both are set" {
  EXPLICIT_DIR="$TEST_TMPDIR/instances/jornada/claude"
  mkdir -p "$EXPLICIT_DIR"

  printf 'CONFIG_BASE_PATH=%s/configs\nREMOTE_SESSION_NAME=jornada\nINSTANCE_CONFIG_PATH=%s\n' "$TMP_PROJECT" "$EXPLICIT_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/status.sh"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Config path:"*"$EXPLICIT_DIR"* ]]
  [[ "$output" != *"$TMP_PROJECT/configs/jornada"* ]]
}

@test "restore.sh: roundtrip through INSTANCE_CONFIG_PATH restores byte-for-byte to the explicit directory" {
  EXPLICIT_DIR="$TEST_TMPDIR/instances/jornada/claude"
  mkdir -p "$EXPLICIT_DIR"
  echo '{"marker":"original-value"}' > "$EXPLICIT_DIR/settings.json"

  printf 'REMOTE_SESSION_NAME=jornada\nINSTANCE_CONFIG_PATH=%s\n' "$EXPLICIT_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/backup.sh" --quiet
  [ "$status" -eq 0 ]
  ARCHIVE="$(ls "$TMP_PROJECT/backups/jornada"/claude-code-dock-jornada-backup-*.tar.gz)"

  echo '{"marker":"corrupted"}' > "$EXPLICIT_DIR/settings.json"

  run bash -c "echo y | bash '$TMP_PROJECT/scripts/restore.sh' '$ARCHIVE'"
  [ "$status" -eq 0 ]

  CONTENT="$(cat "$EXPLICIT_DIR/settings.json")"
  [ "$CONTENT" = '{"marker":"original-value"}' ]
}

@test "new-session.sh: clears an INSTANCE_CONFIG_PATH inherited from the source .env and warns about it" {
  printf 'REMOTE_SESSION_NAME=old-session\nCONFIG_BASE_PATH=./configs\nINSTANCE_CONFIG_PATH=/some/other/sessions/config\n' > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/new-session.sh" "new-session"
  [ "$status" -eq 0 ]

  [[ "$output" == *"INSTANCE_CONFIG_PATH"*"cleared"* ]]
  NEW_VALUE="$(grep '^INSTANCE_CONFIG_PATH=' "$TMP_PROJECT/.env.new-session" | cut -d'=' -f2-)"
  [ -z "$NEW_VALUE" ]
  # REMOTE_SESSION_NAME/CONTAINER_NAME still get set normally -- only
  # INSTANCE_CONFIG_PATH is special-cased.
  grep -q '^REMOTE_SESSION_NAME=new-session$' "$TMP_PROJECT/.env.new-session"
}

@test "new-session.sh: does not warn when the source .env has no INSTANCE_CONFIG_PATH" {
  printf 'REMOTE_SESSION_NAME=old-session\nCONFIG_BASE_PATH=./configs\n' > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/new-session.sh" "new-session"
  [ "$status" -eq 0 ]

  [[ "$output" != *"INSTANCE_CONFIG_PATH"* ]]
}
