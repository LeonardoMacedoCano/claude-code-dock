#!/usr/bin/env bats

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
  SETTINGS_FILE="$HOME/.claude/settings.json"
  export SETTINGS_FILE
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "creates settings.json with skipDangerousModePermissionPrompt when file does not exist" {
  export CLAUDE_AUTO_APPROVE="true"
  [ ! -f "$SETTINGS_FILE" ]

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$SETTINGS_FILE" ]
  grep -q "skipDangerousModePermissionPrompt" "$SETTINGS_FILE"
}

@test "does not create settings.json when CLAUDE_AUTO_APPROVE=false" {
  export CLAUDE_AUTO_APPROVE="false"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$SETTINGS_FILE" ]
}

@test "does not create settings.json when CLAUDE_AUTO_APPROVE is unset (new default)" {
  unset CLAUDE_AUTO_APPROVE

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$SETTINGS_FILE" ]
}

@test "adds skipDangerousModePermissionPrompt to existing settings.json via jq" {
  if ! command -v jq &>/dev/null; then
    skip "jq not available"
  fi

  export CLAUDE_AUTO_APPROVE="true"
  echo '{"model":"claude-sonnet"}' > "$SETTINGS_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  VALUE="$(jq -r '.skipDangerousModePermissionPrompt' "$SETTINGS_FILE")"
  [ "$VALUE" = "true" ]

  MODEL="$(jq -r '.model' "$SETTINGS_FILE")"
  [ "$MODEL" = "claude-sonnet" ]
}

@test "does not modify existing settings.json when CLAUDE_AUTO_APPROVE=false" {
  export CLAUDE_AUTO_APPROVE="false"
  ORIGINAL='{"model":"claude-sonnet"}'
  echo "$ORIGINAL" > "$SETTINGS_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  CONTENT="$(cat "$SETTINGS_FILE")"
  [ "$CONTENT" = "$ORIGINAL" ]
}

@test "reports local build source when the marker file says local:<path>" {
  export BUILD_SOURCE_FILE="$TEST_TMPDIR/claude-dock-build-source"
  echo "local:/home/user/claude-code-dock" > "$BUILD_SOURCE_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Build source:"*"local clone (CLAUDE_SOURCE_PATH=/home/user/claude-code-dock)"* ]]
}

@test "reports GitHub build source when the marker file says github:<ref>" {
  export BUILD_SOURCE_FILE="$TEST_TMPDIR/claude-dock-build-source"
  echo "github:main" > "$BUILD_SOURCE_FILE"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Build source:"*"GitHub (ref: main)"* ]]
}

@test "omits the build source line when the marker file is absent" {
  export BUILD_SOURCE_FILE="$TEST_TMPDIR/does-not-exist"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Build source:"* ]]
}
