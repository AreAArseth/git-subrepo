#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
linked=$OWNER/linked
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" bar
  git subrepo clone "$UPSTREAM/bar" legacy --history=legacy
  git worktree add -q -b feature "$linked"
  git subrepo branch bar -F
) > /dev/null
status=0
(cd "$linked" && git subrepo clean bar --force) > "$TMP/owner-message" 2>&1 || status=$?
is "$status" 1 'another linked worktree cannot force-delete an owned shared worktree'
like "$(cat "$TMP/owner-message")" 'belongs to another project worktree' \
  'ownership diagnostic names the actual workflow boundary'
test-exists "$repo/.git/tmp/subrepo/bar/"
(cd "$repo" && git subrepo clean bar) > /dev/null
(
  cd "$linked"
  echo 'Linked parent contribution' > bar/linked
  git add .
  git commit -qm 'Linked worktree shared change'
  git subrepo push bar
  cd "$repo"
  git merge -q --no-ff --no-edit feature
  git subrepo pull --all
) > /dev/null
is "$(git --git-dir="$UPSTREAM/bar" show master:linked)" 'Linked parent contribution' \
  'linked worktree and ordinary parent merge synchronize correctly'
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.format)" 2 \
  'mixed --all retains the prefixed format'
is "$(git -C "$repo" config -f legacy/.gitrepo subrepo.commit)" \
  "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" 'mixed --all retains original upstream tracking for legacy mode'

mkdir "$TMP/hold-hooks"
mkfifo "$TMP/ready" "$TMP/release"
cat > "$TMP/hold-hooks/pre-commit" <<EOF
#!/bin/sh
printf 'ready\n' > "$TMP/ready"
read answer < "$TMP/release"
EOF
chmod +x "$TMP/hold-hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hold-hooks"
exec 8<>"$TMP/release"
exec 9<>"$TMP/ready"
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" another) > "$TMP/holding" 2>&1 &
writer=$!
if ! read -r -t 30 -u 9 signal; then
  kill "$writer" 2>/dev/null || true
  wait "$writer" || true
  cat "$TMP/holding" >&2
  die 'writer did not reach the deterministic barrier'
fi
is "$signal" ready 'the actual writer reached the commit-hook barrier'
status=0
(cd "$linked" && git subrepo fetch bar) > "$TMP/concurrent" 2>&1 || status=$?
is "$status" 1 'a simultaneous linked-worktree operation is refused while the actual writer holds the lock'
like "$(cat "$TMP/concurrent")" 'Another shared-repository operation is active' \
  'concurrent operation explains the busy state'
printf 'continue\n' >&8
wait "$writer"
exec 8>&-
exec 9>&-
git -C "$repo" config --unset core.hooksPath
(cd "$linked" && git subrepo fetch bar) > /dev/null
is "$(git -C "$repo" status --porcelain)" "" 'completed serialized writer leaves a clean parent'

done_testing
teardown
