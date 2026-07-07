#!/usr/bin/env bats

# Covers the root step-down block at the very top of entrypoint.sh (PUID/PGID
# support). These tests fake "running as root" by mocking `id` itself --
# every other entrypoint test in this suite runs as whatever real UID the
# test runner has (non-root, same as this project's own CI), which never
# triggers this block at all. That's exactly why it needs its own explicit
# coverage: without it, the block could break silently and nothing here
# would ever exercise it.

load helpers

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
ENTRYPOINT="$PROJECT_ROOT/docker/entrypoint.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR
  setup_entrypoint_env
  # setup_entrypoint_env's _mock_sleep just touches a sentinel and exits --
  # good enough for the existing fatal() tests, but here we also need to
  # tell the two code paths ("PUID/PGID validation failed" vs "normal fatal()
  # further down the script") apart, so overwrite it with one that also
  # records which invocation reached it.
  cat > "$MOCK_BIN/sleep" << EOF
#!/bin/bash
echo "sleep infinity called" >> "${TEST_TMPDIR}/sleep_calls"
exit 0
EOF
  chmod +x "$MOCK_BIN/sleep"

  echo 0 > "$TEST_TMPDIR/mock_uid"
  _mock_root_tools
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

# Fakes `id -u` returning root (0) until the mocked setpriv "drops" to a
# non-root uid, so the second (post step-down) pass through entrypoint.sh
# takes the normal, already-covered-elsewhere code path instead of looping.
_mock_root_tools() {
  cat > "$MOCK_BIN/id" << EOF
#!/bin/bash
if [ "\$1" = "-u" ]; then
  cat "${TEST_TMPDIR}/mock_uid" 2>/dev/null || echo 0
  exit 0
fi
if [ "\$1" = "-un" ]; then
  echo "node"
  exit 0
fi
exit 1
EOF
  chmod +x "$MOCK_BIN/id"

  cat > "$MOCK_BIN/groupmod" << EOF
#!/bin/bash
echo "groupmod \$*" >> "${TEST_TMPDIR}/groupmod_calls"
exit 0
EOF
  chmod +x "$MOCK_BIN/groupmod"

  cat > "$MOCK_BIN/usermod" << EOF
#!/bin/bash
echo "usermod \$*" >> "${TEST_TMPDIR}/usermod_calls"
exit 0
EOF
  chmod +x "$MOCK_BIN/usermod"

  cat > "$MOCK_BIN/chown" << EOF
#!/bin/bash
echo "chown \$*" >> "${TEST_TMPDIR}/chown_calls"
exit 0
EOF
  chmod +x "$MOCK_BIN/chown"

  # Strips setpriv's own leading --flag arguments and execs the rest,
  # simulating a successful privilege drop without actually needing root.
  cat > "$MOCK_BIN/setpriv" << EOF
#!/bin/bash
echo "setpriv \$*" >> "${TEST_TMPDIR}/setpriv_calls"
echo 1000 > "${TEST_TMPDIR}/mock_uid"
ARGS=()
for a in "\$@"; do
  case "\$a" in
    --*) ;;
    *) ARGS+=("\$a") ;;
  esac
done
exec "\${ARGS[@]}"
EOF
  chmod +x "$MOCK_BIN/setpriv"
}

@test "running as root with default PUID/PGID: steps down via setpriv without remapping node" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$TEST_TMPDIR/setpriv_calls" ]
  [ ! -f "$TEST_TMPDIR/groupmod_calls" ]
  [ ! -f "$TEST_TMPDIR/usermod_calls" ]
}

@test "running as root with custom PUID/PGID: remaps node and chowns HOME before dropping" {
  export PUID=1005
  export PGID=1005

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ -f "$TEST_TMPDIR/groupmod_calls" ]
  grep -q -- "-g 1005 node" "$TEST_TMPDIR/groupmod_calls"
  [ -f "$TEST_TMPDIR/usermod_calls" ]
  grep -q -- "-u 1005 node" "$TEST_TMPDIR/usermod_calls"
  [ -f "$TEST_TMPDIR/chown_calls" ]
  grep -q "1005:1005" "$TEST_TMPDIR/chown_calls"
  [ -f "$TEST_TMPDIR/setpriv_calls" ]
}

@test "running as root without root (non-root test default) never touches groupmod/usermod/setpriv" {
  echo 1000 > "$TEST_TMPDIR/mock_uid"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]

  [ ! -f "$TEST_TMPDIR/setpriv_calls" ]
  [ ! -f "$TEST_TMPDIR/groupmod_calls" ]
  [ ! -f "$TEST_TMPDIR/usermod_calls" ]
}

@test "PUID=0 is rejected as fatal instead of running as root" {
  export PUID=0
  export PGID=1000

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/sleep_calls" ]
  [[ "$output" == *"PUID/PGID=0 would run Claude Code as root"* ]]
  [ ! -f "$TEST_TMPDIR/setpriv_calls" ]
}

@test "non-numeric PUID is rejected as fatal" {
  export PUID="not-a-number"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/sleep_calls" ]
  [[ "$output" == *"must be positive integers"* ]]
}

@test "PUID/PGID validation failure touches the fatal marker for the watchdog" {
  export PUID=0

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -f "$FATAL_MARKER_FILE" ]
}

@test "groupmod/usermod failure is fatal instead of silently continuing as the wrong user" {
  export PUID=1005
  export PGID=1005
  cat > "$MOCK_BIN/usermod" << 'EOF'
#!/bin/bash
echo "usermod failed" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/usermod"

  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_TMPDIR/sleep_calls" ]
  [[ "$output" == *"could not remap the 'node' account"* ]]
  [ ! -f "$TEST_TMPDIR/setpriv_calls" ]
}
