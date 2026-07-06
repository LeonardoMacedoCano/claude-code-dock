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

  # Single mock covers every `docker inspect --format ...` call status.sh
  # makes (container status/health/uptime, env-var lookup) plus `docker exec
  # ... cat /etc/claude-code-version` -- matched by substring so it doesn't
  # need to track argument order or position.
  cat > "$MOCK_BIN/docker" << 'DOCKEREOF'
#!/bin/bash
ARGS="$*"
case "$ARGS" in
  *".State.Health"*) echo "no healthcheck"; exit 0 ;;
  *".State.Status"*) echo "running"; exit 0 ;;
  *".State.StartedAt"*) echo "2024-01-01T00:00:00Z"; exit 0 ;;
  *"Config.Env"*) printf 'AUTO_START_MODE=interactive\nCLAUDE_AUTO_APPROVE=true\n'; exit 0 ;;
esac
if [ "$1" = "exec" ]; then
  cat "${MOCK_VERSION_FILE}" 2>/dev/null
  exit $?
fi
exit 1
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

_set_installed_version() {
  echo "$1" > "$TEST_TMPDIR/version"
  export MOCK_VERSION_FILE="$TEST_TMPDIR/version"
}

_mock_npm_latest() {
  cat > "$MOCK_BIN/curl" << EOF
#!/bin/bash
echo '{"name":"@anthropic-ai/claude-code","dist-tags":{"latest":"$1"},"version":"$1"}'
exit 0
EOF
  chmod +x "$MOCK_BIN/curl"
}

# Routes `docker exec ... cat <path>` by path, unlike the generic mock in
# setup() which serves MOCK_VERSION_FILE for any exec call regardless of
# which file was requested (fine for version-only tests, not for asserting
# on the separate build-source file).
_mock_docker_exec_routed() {
  local build_source="$1"
  cat > "$MOCK_BIN/docker" << DOCKEREOF
#!/bin/bash
ARGS="\$*"
case "\$ARGS" in
  *".State.Health"*) echo "no healthcheck"; exit 0 ;;
  *".State.Status"*) echo "running"; exit 0 ;;
  *".State.StartedAt"*) echo "2024-01-01T00:00:00Z"; exit 0 ;;
  *"Config.Env"*) printf 'AUTO_START_MODE=interactive\nCLAUDE_AUTO_APPROVE=true\n'; exit 0 ;;
esac
if [ "\$1" = "exec" ]; then
  case "\$ARGS" in
    *claude-dock-build-source*)
      if [ -z "$build_source" ]; then exit 1; fi
      echo "$build_source"; exit 0 ;;
    *claude-code-version*) echo "2.3.1"; exit 0 ;;
  esac
  exit 1
fi
exit 1
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"
}

@test "reports up to date when installed version matches npm latest" {
  _set_installed_version "2.3.1"
  _mock_npm_latest "2.3.1"

  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Up to date:"* ]]
  [[ "$output" == *"yes (latest: 2.3.1)"* ]]
}

@test "reports update available when installed version differs from npm latest" {
  _set_installed_version "2.0.0"
  _mock_npm_latest "2.3.1"

  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Update available:"* ]]
  [[ "$output" == *"2.3.1"* ]]
  [[ "$output" != *"Up to date:"* ]]
}

@test "skips the version comparison when the installed version is unavailable" {
  export MOCK_VERSION_FILE="$TEST_TMPDIR/does-not-exist"
  _mock_npm_latest "2.3.1"

  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unavailable"* ]]
  [[ "$output" != *"Up to date:"* ]]
  [[ "$output" != *"Update available:"* ]]
}

@test "reports latest version unavailable when the npm registry is unreachable" {
  _set_installed_version "2.3.1"
  cat > "$MOCK_BIN/curl" << 'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$MOCK_BIN/curl"

  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Latest version:"*"unavailable (npm registry unreachable)"* ]]
}

@test "reports latest version unavailable when the registry response has no version field" {
  _set_installed_version "2.3.1"
  cat > "$MOCK_BIN/curl" << 'EOF'
#!/bin/bash
echo 'not json'
exit 0
EOF
  chmod +x "$MOCK_BIN/curl"

  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Latest version:"*"unavailable (npm registry unreachable)"* ]]
}

@test "reports local build source with CLAUDE_SOURCE_PATH when marker says local:<path>" {
  _mock_docker_exec_routed "local:/home/user/claude-code-dock"
  _mock_npm_latest "2.3.1"

  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Build source:"*"local clone (CLAUDE_SOURCE_PATH=/home/user/claude-code-dock)"* ]]
}

@test "reports GitHub build source when marker says github:<ref>" {
  _mock_docker_exec_routed "github:main"
  _mock_npm_latest "2.3.1"

  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Build source:"*"GitHub (ref: main)"* ]]
}

@test "omits the build source row when the marker file is unavailable" {
  _mock_docker_exec_routed ""
  _mock_npm_latest "2.3.1"

  run bash "$STATUS_SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Build source:"* ]]
}
