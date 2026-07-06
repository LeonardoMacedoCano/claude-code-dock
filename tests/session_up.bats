#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
SESSION_UP_SCRIPT="$PROJECT_ROOT/scripts/session-up.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Copied into its own scripts/ dir (like backup_retention.bats does for
  # backup.sh) so PROJECT_DIR resolves to this tmpdir instead of the real repo
  # -- .env.* files created below must never touch the actual working tree.
  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  cp "$SESSION_UP_SCRIPT" "$TMP_PROJECT/scripts/session-up.sh"
  touch "$TMP_PROJECT/docker-compose.yml"
  export TMP_PROJECT

  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  cat > "$MOCK_BIN/docker" << 'EOF'
#!/bin/bash
if [ "$1" = "compose" ]; then
  shift
  printf '%s\n' "$@" > "${TEST_TMPDIR}/compose_args"
  exit 0
fi
exit 1
EOF
  chmod +x "$MOCK_BIN/docker"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "no session name: prints usage and exits non-zero without calling compose" {
  run bash "$TMP_PROJECT/scripts/session-up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
  [ ! -f "$TEST_TMPDIR/compose_args" ]
}

@test "no session name: lists existing .env.<name> files as available sessions" {
  touch "$TMP_PROJECT/.env.demo" "$TMP_PROJECT/.env.other"

  run bash "$TMP_PROJECT/scripts/session-up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"demo"* ]]
  [[ "$output" == *"other"* ]]
}

@test "no session name: does not list .env.example as an available session" {
  touch "$TMP_PROJECT/.env.example" "$TMP_PROJECT/.env.demo"

  run bash "$TMP_PROJECT/scripts/session-up.sh"
  [ "$status" -ne 0 ]
  [[ "$output" != *"example"* ]]
  [[ "$output" == *"demo"* ]]
}

@test "missing .env.<name> fails with a clear message instead of calling compose" {
  run bash "$TMP_PROJECT/scripts/session-up.sh" ghost
  [ "$status" -ne 0 ]
  [[ "$output" == *".env.ghost not found"* ]]
  [ ! -f "$TEST_TMPDIR/compose_args" ]
}

@test "valid session: invokes compose with --env-file, its own -p project name, and up -d" {
  echo "REMOTE_SESSION_NAME=demo" > "$TMP_PROJECT/.env.demo"

  run bash "$TMP_PROJECT/scripts/session-up.sh" demo
  [ "$status" -eq 0 ]

  [ -f "$TEST_TMPDIR/compose_args" ]
  grep -q -- "--env-file" "$TEST_TMPDIR/compose_args"
  grep -q "$TMP_PROJECT/.env.demo" "$TEST_TMPDIR/compose_args"
  grep -q -- "-p" "$TEST_TMPDIR/compose_args"
  grep -q "claude-demo" "$TEST_TMPDIR/compose_args"
  grep -q -- "^up$" "$TEST_TMPDIR/compose_args"
  grep -q -- "^-d$" "$TEST_TMPDIR/compose_args"
}

@test "valid session: reports the CONTAINER_NAME declared in its .env file" {
  printf 'REMOTE_SESSION_NAME=demo\nCONTAINER_NAME=my-custom-name\n' > "$TMP_PROJECT/.env.demo"

  run bash "$TMP_PROJECT/scripts/session-up.sh" demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-custom-name"* ]]
}

@test "valid session: falls back to claude-code-dock-<name> when CONTAINER_NAME is not set" {
  echo "REMOTE_SESSION_NAME=demo" > "$TMP_PROJECT/.env.demo"

  run bash "$TMP_PROJECT/scripts/session-up.sh" demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code-dock-demo"* ]]
}
