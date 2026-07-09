#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
STATUS_SCRIPT="$PROJECT_ROOT/scripts/status.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"
  export CONTAINER_NAME="fake-container"

  cat > "$MOCK_BIN/docker" << 'DOCKEREOF'
#!/bin/bash
ARGS="$*"
case "$ARGS" in
  *".State.Health"*) echo "healthy"; exit 0 ;;
  *".State.Status"*) echo "running"; exit 0 ;;
  *".State.StartedAt"*) echo "2024-01-01T00:00:00Z"; exit 0 ;;
  *"Config.Env"*) printf 'AUTO_START_MODE=interactive\nCLAUDE_AUTO_APPROVE=true\n'; exit 0 ;;
esac
if [ "$1" = "exec" ]; then
  case "$ARGS" in
    *claude-dock-build-source*) echo "github:main"; exit 0 ;;
    *claude-code-version*) echo "2.3.1"; exit 0 ;;
  esac
  exit 1
fi
exit 1
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"

  cat > "$MOCK_BIN/curl" << 'CURLEOF'
#!/bin/bash
echo '{"version":"2.3.1"}'
exit 0
CURLEOF
  chmod +x "$MOCK_BIN/curl"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# json.tool round-trips through python's stdlib json module -- available
# wherever bats/CI already runs (no extra dependency), and fails loudly on
# malformed JSON instead of a brittle string-matching approximation.
_assert_valid_json() {
  echo "$1" | python3 -m json.tool >/dev/null
}

@test "--json produces no ANSI escape codes" {
  run bash "$STATUS_SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033'* ]]
}

@test "--json produces valid, parseable JSON" {
  run bash "$STATUS_SCRIPT" --json
  [ "$status" -eq 0 ]
  _assert_valid_json "$output"
}

@test "--json reports container status and health" {
  run bash "$STATUS_SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"status": "running"'* ]]
  [[ "$output" == *'"health": "healthy"'* ]]
}

@test "--json reports claude_code version, mode and auto_approve as a JSON boolean" {
  run bash "$STATUS_SCRIPT" --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version": "2.3.1"'* ]]
  [[ "$output" == *'"mode": "interactive"'* ]]
  [[ "$output" == *'"auto_approve": true'* ]]
}

@test "--json without --json flag still prints human-readable output" {
  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude-code-dock — Status"* ]]
  [[ "$output" != *'"container":'* ]]
}

@test "--json degrades safely when the container does not exist" {
  cat > "$MOCK_BIN/docker" << 'DOCKEREOF'
#!/bin/bash
exit 1
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"

  run bash "$STATUS_SCRIPT" --json
  [ "$status" -eq 0 ]
  _assert_valid_json "$output"
  [[ "$output" == *'"status": "not found"'* ]]
}
