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
INSTALL_SCRIPT="$PROJECT_ROOT/scripts/install.sh"
LOGS_SCRIPT="$PROJECT_ROOT/scripts/logs.sh"

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
  cp "$INSTALL_SCRIPT" "$TMP_PROJECT/scripts/install.sh"
  cp "$LOGS_SCRIPT" "$TMP_PROJECT/scripts/logs.sh"
  touch "$TMP_PROJECT/docker-compose.yml"

  mkdir -p "$TMP_PROJECT/backups"

  # install.sh's own tests below are the only ones in this file that ever
  # invoke `docker`/`docker compose` -- everything else (backup/restore/
  # status/new-session) never shells out to Docker at all, so this mock
  # being present is a no-op for those.
  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"
  cat > "$MOCK_BIN/docker" << 'DOCKEREOF'
#!/bin/bash
ARGS="$*"
case "$ARGS" in
  --version) echo "Docker version 24.0.0, build deadbeef"; exit 0 ;;
  info) exit 0 ;;
  "compose version --short"*) echo "2.20.0"; exit 0 ;;
  "compose version"*) echo "Docker Compose version v2.20.0"; exit 0 ;;
  "compose "*"pull"*) exit 0 ;;
  "compose "*"up -d"*) exit 0 ;;
  "inspect --format {{.State.Running}}"*) echo "true"; exit 0 ;;
esac
exit 0
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"

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

@test "install.sh: creates and reports the INSTANCE_CONFIG_PATH directory when CONFIG_BASE_PATH is unset" {
  EXPLICIT_DIR="$TEST_TMPDIR/instances/jornada/claude"
  # Deliberately not pre-created -- install.sh must create it itself, same
  # as it already does for CONFIG_BASE_PATH/REMOTE_SESSION_NAME.
  [ ! -d "$EXPLICIT_DIR" ]

  printf 'REMOTE_SESSION_NAME=jornada\nWORKSPACE_PATH=./workspaces\nINSTANCE_CONFIG_PATH=%s\n' "$EXPLICIT_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/install.sh"
  [ "$status" -eq 0 ]

  [[ "$output" == *"Session config dir (INSTANCE_CONFIG_PATH): $EXPLICIT_DIR"* ]]
  [ -d "$EXPLICIT_DIR" ]
}

@test "install.sh: INSTANCE_CONFIG_PATH wins over a CONFIG_BASE_PATH decoy, and does not create the decoy" {
  EXPLICIT_DIR="$TEST_TMPDIR/instances/jornada/claude"

  printf 'REMOTE_SESSION_NAME=jornada\nWORKSPACE_PATH=./workspaces\nCONFIG_BASE_PATH=%s/configs\nINSTANCE_CONFIG_PATH=%s\n' \
    "$TMP_PROJECT" "$EXPLICIT_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/install.sh"
  [ "$status" -eq 0 ]

  [ -d "$EXPLICIT_DIR" ]
  [ ! -d "$TMP_PROJECT/configs/jornada" ]
}

@test "install.sh: fails clearly when neither CONFIG_BASE_PATH nor INSTANCE_CONFIG_PATH is set" {
  printf 'REMOTE_SESSION_NAME=jornada\nWORKSPACE_PATH=./workspaces\n' > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Neither INSTANCE_CONFIG_PATH nor CONFIG_BASE_PATH is set"* ]]
}

@test "logs.sh --app: finds the startup log via INSTANCE_CONFIG_PATH instead of CONFIG_BASE_PATH/REMOTE_SESSION_NAME" {
  EXPLICIT_DIR="$TEST_TMPDIR/instances/jornada/claude"
  mkdir -p "$EXPLICIT_DIR/logs"
  echo "startup log line" > "$EXPLICIT_DIR/logs/dock.log"

  printf 'REMOTE_SESSION_NAME=jornada\nINSTANCE_CONFIG_PATH=%s\n' "$EXPLICIT_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/logs.sh" --app --no-follow
  [ "$status" -eq 0 ]
  [[ "$output" == *"startup log line"* ]]
}

@test "logs.sh --app: reports 'not found' instead of silently reading the wrong file when only INSTANCE_CONFIG_PATH is set" {
  # No file exists at the legacy CONFIG_BASE_PATH=./configs, REMOTE_SESSION_NAME=default
  # location this used to hardcode -- confirms it actually followed
  # INSTANCE_CONFIG_PATH's resolution instead of falling back silently.
  EXPLICIT_DIR="$TEST_TMPDIR/instances/jornada/claude"
  printf 'REMOTE_SESSION_NAME=jornada\nINSTANCE_CONFIG_PATH=%s\n' "$EXPLICIT_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/logs.sh" --app --no-follow
  [ "$status" -ne 0 ]
  [[ "$output" == *"No startup log found yet"* ]]
  [[ "$output" == *"$EXPLICIT_DIR/logs/dock.log"* ]]
}
