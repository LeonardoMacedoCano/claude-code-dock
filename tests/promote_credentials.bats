#!/usr/bin/env bats

# Covers scripts/promote-credentials.sh: the explicit, operator-run
# promotion step for SHARED_CREDENTIALS_MODE=seed (see
# entrypoint_shared_credentials_seed.bats for the entrypoint side).

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
PROMOTE_SCRIPT="$PROJECT_ROOT/scripts/promote-credentials.sh"

setup() {
  unset CONFIG_BASE_PATH REMOTE_SESSION_NAME INSTANCE_CONFIG_PATH SHARED_CREDENTIALS_PATH

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  cp -r "$PROJECT_ROOT/scripts/lib" "$TMP_PROJECT/scripts/lib"
  cp "$PROMOTE_SCRIPT" "$TMP_PROJECT/scripts/promote-credentials.sh"

  SHARED_DIR="$TEST_TMPDIR/shared-credentials"
  CONFIG_DIR="$TMP_PROJECT/configs/jornada"
  mkdir -p "$CONFIG_DIR"

  export TMP_PROJECT SHARED_DIR CONFIG_DIR
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_write_env() {
  printf 'CONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=jornada\nSHARED_CREDENTIALS_PATH=%s\n' "$SHARED_DIR" > "$TMP_PROJECT/.env"
}

@test "fails clearly when SHARED_CREDENTIALS_PATH is not set" {
  printf 'CONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=jornada\n' > "$TMP_PROJECT/.env"
  echo '{"token":"my-login"}' > "$CONFIG_DIR/.credentials.json"

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SHARED_CREDENTIALS_PATH is not set"* ]]
}

@test "fails clearly when the instance config directory cannot be resolved" {
  printf 'SHARED_CREDENTIALS_PATH=%s\n' "$SHARED_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot find this instance's config directory"* ]]
}

@test "fails clearly when no login exists yet" {
  _write_env

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"No login found"* ]]
}

@test "refuses to promote from a live-mode symlink and explains why" {
  _write_env
  mkdir -p "$SHARED_DIR"
  echo '{"token":"already-live-synced"}' > "$SHARED_DIR/.credentials.json"
  ln -s "$SHARED_DIR/.credentials.json" "$CONFIG_DIR/.credentials.json"

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"already syncs automatically"* ]]
}

@test "happy path: copies this instance's login into an empty shared pool" {
  _write_env
  echo '{"token":"my-login"}' > "$CONFIG_DIR/.credentials.json"

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh"
  [ "$status" -eq 0 ]

  grep -q "my-login" "$SHARED_DIR/.credentials.json"
  [ ! -L "$SHARED_DIR/.credentials.json" ]
  [[ "$output" == *"Promoted"* ]]
}

@test "declining the overwrite confirmation leaves the shared pool untouched" {
  _write_env
  echo '{"token":"new-login"}' > "$CONFIG_DIR/.credentials.json"
  mkdir -p "$SHARED_DIR"
  echo '{"token":"old-shared-login"}' > "$SHARED_DIR/.credentials.json"

  run bash -c "echo n | bash '$TMP_PROJECT/scripts/promote-credentials.sh'"
  [ "$status" -eq 0 ]

  grep -q "old-shared-login" "$SHARED_DIR/.credentials.json"
  ! grep -q "new-login" "$SHARED_DIR/.credentials.json"
}

@test "accepting the overwrite confirmation replaces the shared pool" {
  _write_env
  echo '{"token":"new-login"}' > "$CONFIG_DIR/.credentials.json"
  mkdir -p "$SHARED_DIR"
  echo '{"token":"old-shared-login"}' > "$SHARED_DIR/.credentials.json"

  run bash -c "echo y | bash '$TMP_PROJECT/scripts/promote-credentials.sh'"
  [ "$status" -eq 0 ]

  grep -q "new-login" "$SHARED_DIR/.credentials.json"
}

@test "--force skips the confirmation prompt" {
  _write_env
  echo '{"token":"new-login"}' > "$CONFIG_DIR/.credentials.json"
  mkdir -p "$SHARED_DIR"
  echo '{"token":"old-shared-login"}' > "$SHARED_DIR/.credentials.json"

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh" --force
  [ "$status" -eq 0 ]

  grep -q "new-login" "$SHARED_DIR/.credentials.json"
}

@test "identical content in both places needs no confirmation" {
  _write_env
  echo '{"token":"same-login"}' > "$CONFIG_DIR/.credentials.json"
  mkdir -p "$SHARED_DIR"
  echo '{"token":"same-login"}' > "$SHARED_DIR/.credentials.json"

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Continue?"* ]]
}

@test "works with INSTANCE_CONFIG_PATH instead of CONFIG_BASE_PATH+REMOTE_SESSION_NAME" {
  EXPLICIT_DIR="$TEST_TMPDIR/instances/jornada/claude"
  mkdir -p "$EXPLICIT_DIR"
  echo '{"token":"explicit-path-login"}' > "$EXPLICIT_DIR/.credentials.json"
  printf 'INSTANCE_CONFIG_PATH=%s\nSHARED_CREDENTIALS_PATH=%s\n' "$EXPLICIT_DIR" "$SHARED_DIR" > "$TMP_PROJECT/.env"

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh"
  [ "$status" -eq 0 ]

  grep -q "explicit-path-login" "$SHARED_DIR/.credentials.json"
}

@test "session-name argument uses .env.<name> instead of .env" {
  echo '{"token":"named-session-login"}' > "$CONFIG_DIR/.credentials.json"
  printf 'CONFIG_BASE_PATH=./configs\nREMOTE_SESSION_NAME=jornada\nSHARED_CREDENTIALS_PATH=%s\n' "$SHARED_DIR" > "$TMP_PROJECT/.env.jornada"

  run bash "$TMP_PROJECT/scripts/promote-credentials.sh" jornada
  [ "$status" -eq 0 ]

  grep -q "named-session-login" "$SHARED_DIR/.credentials.json"
}

@test "missing .env.<name> fails with a clear message" {
  run bash "$TMP_PROJECT/scripts/promote-credentials.sh" nonexistent-session
  [ "$status" -ne 0 ]
  [[ "$output" == *".env.nonexistent-session not found"* ]]
}
