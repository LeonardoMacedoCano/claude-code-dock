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

@test "GITHUB_TOKEN_FILE pointing at a populated file writes .git-credentials" {
  echo "ghp_fromfile" > "$TEST_TMPDIR/token_file"
  export GITHUB_TOKEN_FILE="$TEST_TMPDIR/token_file"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$HOME/.git-credentials" ]
  grep -q "ghp_fromfile" "$HOME/.git-credentials"
  [[ "$output" == *"GitHub token: configured"* ]]
}

@test "GITHUB_TOKEN_FILE pointing at a missing path is a silent no-op" {
  export GITHUB_TOKEN_FILE="$TEST_TMPDIR/does-not-exist"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$HOME/.git-credentials" ]
  [[ "$output" != *"GitHub token"* ]]
}

@test "GITHUB_TOKEN_FILE pointing at an empty file (the /dev/null idiom) is a silent no-op" {
  : > "$TEST_TMPDIR/empty_token_file"
  export GITHUB_TOKEN_FILE="$TEST_TMPDIR/empty_token_file"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$HOME/.git-credentials" ]
  [[ "$output" != *"GitHub token"* ]]
}

@test "GITHUB_TOKEN_FILE pointing at a directory warns instead of crashing" {
  mkdir -p "$TEST_TMPDIR/token_as_dir"
  export GITHUB_TOKEN_FILE="$TEST_TMPDIR/token_as_dir"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$HOME/.git-credentials" ]
  [[ "$output" == *"is a directory, not a file"* ]]
}

@test "GITHUB_TOKEN_FILE unset falls back to the fixed convention path (/run/secrets/github_token)" {
  unset GITHUB_TOKEN_FILE
  # Real path is outside this test's sandboxed $HOME and won't exist on a
  # normal test runner, so this only asserts the no-token-configured
  # behavior -- it can't redirect the hardcoded default elsewhere.
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.git-credentials" ]
}
