#!/usr/bin/env bats

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
}

teardown() {
  rm -rf "$TEST_TMPDIR"
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
