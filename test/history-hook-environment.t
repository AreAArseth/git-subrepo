#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
unset GIT_SUBREPO_RUNNING GIT_SUBREPO_COMMAND

repo=$OWNER/foo
mkdir "$TMP/hooks"
export TEST_HOOK_LOG="$TMP/hook-environment"
export TEST_HOOK_INTERRUPT="$TMP/interrupt"
cat > "$TMP/hooks/pre-commit" <<'EOF'
#!/bin/sh
printf '%s\n' "${GIT_SUBREPO_RUNNING-unset}" "${GIT_SUBREPO_COMMAND-unset}" > "$TEST_HOOK_LOG"
if [ -n "${GIT_SUBREPO_RUNNING-}" ] && kill -0 "$GIT_SUBREPO_RUNNING" 2>/dev/null; then
  echo live >> "$TEST_HOOK_LOG"
else
  echo missing >> "$TEST_HOOK_LOG"
fi
if [ -f "$TEST_HOOK_INTERRUPT" ]; then
  kill -TERM "$GIT_SUBREPO_RUNNING"
  exit 1
fi
EOF
chmod +x "$TMP/hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hooks"

(cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar) > "$TMP/clone" 2>&1
like "$(sed -n '1p' "$TEST_HOOK_LOG")" '^[1-9][0-9]*$' \
  'normal integration exports a process ID to its commit hook'
is "$(sed -n '2p' "$TEST_HOOK_LOG")" clone \
  'normal integration exports the current command to its commit hook'
is "$(sed -n '3p' "$TEST_HOOK_LOG")" live \
  'normal integration identifies a running process'
is "$(git -C "$repo" status --porcelain)" "" 'normal integration leaves a clean project'

(
  cd "$OWNER/bar"
  echo recovered > incoming
  git add incoming
  git commit -qm 'Incoming hook environment fixture'
  git push -q
)
before=$(git -C "$repo" rev-parse HEAD)
touch "$TEST_HOOK_INTERRUPT"
status=0
(cd "$repo" && git subrepo pull bar) > "$TMP/interrupted" 2>&1 || status=$?
is "$status" 143 'a real hook interrupts integration with SIGTERM'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'interruption preserves the parent commit'
test-exists "$repo/.git/subrepo-integration"
is "$(sed -n '2p' "$TEST_HOOK_LOG")" pull \
  'the interrupted hook sees the current pull command'
rm "$TEST_HOOK_INTERRUPT" "$TEST_HOOK_LOG"

# Recovery commits before the normal working-copy checks, but must still
# initialize the documented hook environment.
status=0
(cd "$repo" && git subrepo pull bar) > "$TMP/resumed" 2>&1 || status=$?
is "$status" 0 'the exact retry completes the interrupted integration'
like "$(sed -n '1p' "$TEST_HOOK_LOG")" '^[1-9][0-9]*$' \
  'resumed integration exports a process ID to its commit hook'
is "$(sed -n '2p' "$TEST_HOOK_LOG")" pull \
  'resumed integration exports the current command to its commit hook'
is "$(sed -n '3p' "$TEST_HOOK_LOG")" live \
  'resumed integration identifies a running process'
like "$(cat "$TMP/resumed")" 'Completed the interrupted update' \
  'the retry takes the integration recovery path'
is "$(cat "$repo/bar/incoming")" recovered 'recovery imports the prepared content'
is "$(git -C "$repo" rev-parse HEAD^1)" "$before" 'recovery records one parent integration'
is "$(git -C "$repo" status --porcelain)" "" 'recovery leaves a clean project'
test-exists "!$repo/.git/subrepo-integration"

done_testing
teardown
