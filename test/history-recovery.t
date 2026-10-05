#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

for mode in squash rebase cherry; do
  repo=$OWNER/$mode
  fresh=$OWNER/$mode-fresh
  git clone -q "$OWNER/foo" "$repo"
  (
    cd "$repo"
    git subrepo clone "$UPSTREAM/bar" bar
    git checkout -qb feature
    echo 'Feature parent content' > feature-parent
    git add .
    git commit -qm 'Feature parent change'
  ) > /dev/null 2>&1
  (
    cd "$OWNER/bar"
    echo "$mode incoming" > "incoming-$mode"
    git add .
    git commit -qm "Upstream $mode change"
    git push -q
  )
  (
    cd "$repo"
    git subrepo pull bar
    git rev-parse HEAD > "$TMP/import-$mode"
    echo "$mode local residual" > "bar/local-$mode"
    git add .
    git commit -qm "Local $mode residual"
    git rev-parse HEAD > "$TMP/local-$mode"
    git checkout -q master
    case "$mode" in
      squash)
        git merge -q --squash feature
        git commit -qm 'Squashed parent feature'
        ;;
      rebase)
        # Rebase a linear commit carrying the synchronization metadata, as with
        # a previously squash-integrated feature. Recreating a merge alone can
        # instead drop the merge's metadata edit, which is a different workflow.
        git checkout -qb linear
        git merge -q --squash feature
        git commit -qm 'Linear shared synchronization'
        git checkout -q master
        echo 'Main parent content' > main-parent
        git add .
        git commit -qm 'Main parent change'
        git checkout -q linear
        git rebase master
        git checkout -q master
        git merge -q --ff-only linear
        ;;
      cherry)
        git cherry-pick -m 1 "$(cat "$TMP/import-$mode")"
        git cherry-pick "$(cat "$TMP/local-$mode")"
        ;;
    esac
  ) > "$TMP/$mode-setup.log" 2>&1
  git clone -q --no-local --single-branch --branch master "$repo" "$fresh"
  before=$(git -C "$fresh" rev-parse HEAD)
  old_parent=$(git -C "$fresh" config -f bar/.gitrepo subrepo-v2.parent)
  status=0
  git -C "$fresh" merge-base --is-ancestor "$old_parent" HEAD > /dev/null 2>&1 || status=$?
  isnt "$status" 0 "$mode fixture actually loses the recorded sync ancestry"

  status=0
  (cd "$fresh" && git subrepo push bar) > "$TMP/$mode-proposal" 2>&1 || status=$?
  is "$status" 1 "$mode repair requires explicit noninteractive approval"
  is "$(git -C "$fresh" rev-parse HEAD)" "$before" "$mode refusal preserves HEAD"
  is "$(git -C "$fresh" status --porcelain)" "" "$mode refusal preserves the index and worktree"
  like "$(cat "$TMP/$mode-proposal")" 'Your shared content and other project files will stay the same' \
    "$mode proposal explains content safety"
  like "$(cat "$TMP/$mode-proposal")" 'send your shared changes upstream' \
    "$mode proposal explains push follow-through"
  token=$(sed -n 's/.*--accept-repair=\([a-f0-9]*\).*/\1/p' "$TMP/$mode-proposal" | tail -1)
  isnt "$token" "" "$mode proposal provides a state-bound approval token"
  status=0
  (cd "$fresh" && git subrepo push bar --accept-repair=wrong) > "$TMP/stale" 2>&1 || status=$?
  is "$status" 1 'invalid approval is rejected'
  is "$(git -C "$fresh" rev-parse HEAD)" "$before" 'invalid approval does not change HEAD'

  (cd "$fresh" && git subrepo push bar --accept-repair="$token") > "$TMP/$mode-repaired" 2>&1
  is "$(cat "$fresh/bar/local-$mode")" "$mode local residual" \
    "$mode repair retains the local shared result"
  is "$(git --git-dir="$UPSTREAM/bar" show "master:local-$mode")" "$mode local residual" \
    "$mode repair exports the residual to the actual upstream"
  is "$(git -C "$fresh" diff --name-only "$before" HEAD -- . ':(exclude)bar/.gitrepo')" "" \
    "$mode recovery and push change only tracking metadata"
  mapped=$(git -C "$fresh" config -f bar/.gitrepo subrepo-v2.mappedCommit)
  git -C "$fresh" merge-base --is-ancestor "$mapped" HEAD
  is "$(git -C "$fresh" status --porcelain)" "" "$mode completed recovery leaves a clean parent"
  after=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
  (cd "$fresh" && git subrepo push bar) > /dev/null 2>&1
  is "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" "$after" \
    "$mode retry does not export the residual again"
  (cd "$OWNER/bar" && git pull -q)
done

done_testing
teardown
