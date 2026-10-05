#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
(
  cd "$OWNER/bar"
  echo base > Bar
  git add .
  git commit -qm 'Shared baseline'
  git push -q
  cd "$OWNER/foo"
  git subrepo clone "$UPSTREAM/bar" bar
  echo local > bar/Bar
  git add .
  git commit -qm 'Local edit'
  cd "$OWNER/bar"
  echo incoming > Bar
  git add .
  git commit -qm 'Incoming edit'
  git push -q
) > /dev/null
before=$(git -C "$OWNER/foo" rev-parse HEAD)
status=0
(cd "$OWNER/foo" && git subrepo pull bar) > "$TMP/conflict" 2>&1 || status=$?
is "$status" 1 'a real conflicting pull stops for resolution'
is "$(git -C "$OWNER/foo" rev-parse HEAD)" "$before" 'conflict leaves parent HEAD unchanged'
like "$(cat "$TMP/conflict")" 'Edit the conflicted files there' \
  'conflict tells non-experts which worktree to edit and how to continue'
worktree=$OWNER/foo/.git/tmp/subrepo/bar
is "$(cat "$OWNER/foo/bar/Bar")" local 'parent content remains unchanged during conflict'
is "$(git -C "$worktree" ls-files .gitrepo)" "" 'upstream-layout worktree contains no metadata'
(
  cd "$worktree"
  echo resolved > Bar
  git add Bar
  git commit -qm 'Resolve shared conflict'
  cd "$OWNER/foo"
  git subrepo commit bar
  git subrepo push bar
  cd "$OWNER/bar"
  git pull -q
) > /dev/null
is "$(cat "$OWNER/bar/Bar")" resolved 'manual conflict resolution is exported intact'
is "$(cat "$OWNER/foo/bar/Bar")" resolved 'manual commit installs the resolved parent content'

(
  cd "$OWNER/bar"
  git checkout -qb upstream-feature
  echo side > side
  git add .
  git commit -qm 'Upstream side'
  git checkout -q master
  echo main > main
  git add .
  git commit -qm 'Upstream main'
  git merge -q --no-ff --no-edit upstream-feature
  git push -q
  cd "$OWNER/foo"
  git subrepo pull bar
) > /dev/null
mapped=$(git -C "$OWNER/foo" config -f bar/.gitrepo subrepo-v2.mappedCommit)
is "$(git -C "$OWNER/foo" show -s --format=%P "$mapped" | wc -w | tr -d ' ')" 2 \
  'an upstream merge retains both mapped parents'
is "$(git -C "$OWNER/foo" rev-parse "$mapped:bar")" \
  "$(git -C "$OWNER/bar" rev-parse 'HEAD^{tree}')" 'mapped upstream merge preserves the full resolved tree'

(
  cd "$OWNER/foo"
  echo one > bar/one
  git add .
  git commit -qm 'First squash contribution'
  echo two > bar/two
  git add .
  git commit -qm 'Second squash contribution'
  git subrepo push bar --squash
  git subrepo log bar --group-equivalent --oneline > "$TMP/grouped"
) > /dev/null
like "$(cat "$TMP/grouped")" 'Same shared change' 'squashed export exposes verified aggregate grouping'
is "$(git --git-dir="$UPSTREAM/bar" show master:one)" one 'squashed export preserves first contribution'
is "$(git --git-dir="$UPSTREAM/bar" show master:two)" two 'squashed export preserves second contribution'
is "$(git -C "$OWNER/foo" status --porcelain)" "" 'merge, conflict, and squash sequence leaves a clean parent'

done_testing
teardown
