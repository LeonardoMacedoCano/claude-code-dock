#!/usr/bin/env bats

# Regression coverage for update.sh's attempt_rollback(): when
# CLAUDE_SOURCE_PATH is set, docker-compose.override.yml pins
# `pull_policy: build`, which makes Compose rebuild the image on every `up`
# -- including the `up -d --force-recreate` attempt_rollback() runs right
# after re-tagging the previous image. Without pinning `pull_policy: never`
# for that one call, the rebuild silently overwrites the retag with the
# same (still broken) image built from the current CLAUDE_SOURCE_PATH,
# defeating the rollback. This asserts the extra `-f <file>` passed to that
# specific `up -d --force-recreate` call actually contains `pull_policy: never`.

PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
UPDATE_SCRIPT="$PROJECT_ROOT/scripts/update.sh"

setup() {
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  TMP_PROJECT="$TEST_TMPDIR/project"
  mkdir -p "$TMP_PROJECT/scripts"
  cp "$UPDATE_SCRIPT" "$TMP_PROJECT/scripts/update.sh"
  touch "$TMP_PROJECT/docker-compose.yml"
  export TMP_PROJECT

  printf 'CONTAINER_NAME=test-container\nCLAUDE_SOURCE_PATH=/fake/source\n' > "$TMP_PROJECT/.env"

  MOCK_BIN="$TEST_TMPDIR/bin"
  mkdir -p "$MOCK_BIN"
  export PATH="$MOCK_BIN:$PATH"

  FORCE_RECREATE_LOG="$TEST_TMPDIR/force_recreate_extra_f_contents"
  export FORCE_RECREATE_LOG
  UPDATED_MARKER="$TEST_TMPDIR/updated_once"
  export UPDATED_MARKER

  # Container never becomes Running/healthy after the plain `up -d` in
  # start_container(), forcing update.sh into attempt_rollback(). The image
  # id reported by `docker inspect --format {{.Image}}` changes after the
  # first `up -d` -- simulating "now running a different (broken) image" --
  # so attempt_rollback()'s own "same image, nothing to roll back" shortcut
  # doesn't short-circuit before reaching the recreate call under test.
  cat > "$MOCK_BIN/docker" << 'DOCKEREOF'
#!/bin/bash
ARGS="$*"

case "$ARGS" in
  "compose version"*) exit 0 ;;
  *"ps --filter name=test-container --filter status=running"*) exit 0 ;;
  *"inspect --format {{.Image}} test-container"*)
    if [ -f "$UPDATED_MARKER" ]; then echo "sha256:newbrokenimage"; else echo "sha256:oldworkingimage"; fi
    exit 0 ;;
  *"inspect --format {{.Config.Image}} test-container"*)
    echo "claude-code-dock:local"; exit 0 ;;
  *"inspect --format {{.State.Running}} test-container"*)
    echo "false"; exit 0 ;;
  *"inspect --format {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} test-container"*)
    echo "unhealthy"; exit 0 ;;
  *"tag sha256:oldworkingimage claude-code-dock:local"*)
    exit 0 ;;
  *"image prune"*)
    exit 0 ;;
esac

if [ "$1" = "compose" ]; then
  shift
  if [[ "$*" == *"--force-recreate"* ]]; then
    : > "$FORCE_RECREATE_LOG"
    prev=""
    for arg in "$@"; do
      if [ "$prev" = "-f" ] && [ -f "$arg" ]; then
        cat "$arg" >> "$FORCE_RECREATE_LOG"
        echo "---" >> "$FORCE_RECREATE_LOG"
      fi
      prev="$arg"
    done
    touch "$UPDATED_MARKER"
    exit 0
  fi
  touch "$UPDATED_MARKER"
  exit 0
fi
exit 1
DOCKEREOF
  chmod +x "$MOCK_BIN/docker"
}

teardown() {
  rm -rf "$TEST_TMPDIR"
}

@test "attempt_rollback pins pull_policy: never so the retagged image isn't rebuilt over" {
  run env WAIT_FOR_CONTAINER_TIMEOUT=1 WAIT_FOR_HEALTHY_TIMEOUT=1 \
      bash "$TMP_PROJECT/scripts/update.sh" --skip-backup

  [ -f "$FORCE_RECREATE_LOG" ]
  grep -q "pull_policy: never" "$FORCE_RECREATE_LOG"
}

@test "attempt_rollback re-tags the previous image before recreating" {
  run env WAIT_FOR_CONTAINER_TIMEOUT=1 WAIT_FOR_HEALTHY_TIMEOUT=1 \
      bash "$TMP_PROJECT/scripts/update.sh" --skip-backup

  [[ "$output" == *"Re-tagged claude-code-dock:local back onto the previous image"* ]]
}
