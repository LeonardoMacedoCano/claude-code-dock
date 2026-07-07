#!/usr/bin/env bats

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
WATCHDOG_SCRIPT="$PROJECT_ROOT/scripts/watchdog.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_mock_docker() {
  local health="$1"
  cat > "$MOCK_BIN/docker" << DOCKEREOF
#!/bin/bash
ARGS="\$*"
case "\$ARGS" in
  *"inspect --format {{.State.Health.Status}}"*) echo "${health}"; exit 0 ;;
  *"inspect fake-container"*) exit 0 ;;
  *"restart"*) echo "restarted \$2"; exit 0 ;;
esac
exit 1
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"
}

@test "unhealthy container triggers a docker restart" {
  _mock_docker "unhealthy"
  run bash "$WATCHDOG_SCRIPT" fake-container
  [ "$status" -eq 0 ]
  [[ "$output" == *"unhealthy"* ]]
  [[ "$output" == *"restarted"* ]]
}

@test "healthy container is left alone" {
  _mock_docker "healthy"
  run bash "$WATCHDOG_SCRIPT" fake-container
  [ "$status" -eq 0 ]
  [[ "$output" == *"healthy"* ]]
  [[ "$output" != *"restart"* ]]
}

@test "starting container (within start-period) is left alone" {
  _mock_docker "starting"
  run bash "$WATCHDOG_SCRIPT" fake-container
  [ "$status" -eq 0 ]
  [[ "$output" == *"starting"* ]]
  [[ "$output" != *"docker restart"* ]]
}

@test "container without a healthcheck is a no-op, not an error" {
  cat > "$MOCK_BIN/docker" << 'DOCKEREOF'
#!/bin/bash
ARGS="$*"
case "$ARGS" in
  *"inspect --format {{.State.Health.Status}}"*) echo ""; exit 0 ;;
  *"inspect fake-container"*) exit 0 ;;
esac
exit 1
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"

  run bash "$WATCHDOG_SCRIPT" fake-container
  [ "$status" -eq 0 ]
  [[ "$output" == *"no healthcheck"* ]]
}

@test "container that does not exist fails loudly" {
  cat > "$MOCK_BIN/docker" << 'DOCKEREOF'
#!/bin/bash
exit 1
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"

  run bash "$WATCHDOG_SCRIPT" missing-container
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "defaults to CONTAINER_NAME from environment when no argument is given" {
  _mock_docker "healthy"
  export CONTAINER_NAME="fake-container"
  run bash "$WATCHDOG_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"fake-container"* ]]
  unset CONTAINER_NAME
}
