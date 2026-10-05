#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
original=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
for method in merge rebase; do
  repo=$OWNER/project-$method
  remote="$UPSTREAM/target $method"
  branch=target-$method
  prefix='shared files'
  git clone -q "$UPSTREAM/foo" "$repo"
  git clone -q --bare "$UPSTREAM/bar" "$remote"
  git clone -q "$remote" "$OWNER/target-$method"
  (
    cd "$repo"
    git subrepo clone "$UPSTREAM/bar" "$prefix" --method="$method"
    echo local > "$prefix/ReadMe"
    echo local > "$prefix/local-only"
    git add .
    git commit -qm 'Local conflicting contribution'
    cd "$OWNER/target-$method"
    git checkout -qb "$branch"
    echo remote > ReadMe
    echo remote > remote-only
    git add .
    git commit -qm 'Remote conflicting contribution'
    git push -q origin "$branch"
  ) > /dev/null
  before=$(git -C "$repo" rev-parse HEAD)
  status=0
  (
    cd "$repo"
    git subrepo retarget "$prefix" --remote "$remote" --branch "$branch"
  ) > "$TMP/conflict" 2>&1 || status=$?
  is "$status" 1 "retarget stops for a real $method conflict"
  retry=$(printf 'git subrepo retarget %q --remote %q --branch %q' "$prefix" "$remote" "$branch")
  is "$(tail -n 1 "$TMP/conflict")" "  $retry" \
    'conflict guidance preserves the original retarget command and quoted overrides'
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'conflict leaves the parent commit untouched'
  worktree=$repo/.git/tmp/subrepo/shared%20files
  echo "resolved-$method" > "$worktree/ReadMe"
  git -C "$worktree" add ReadMe
  if [[ $method == rebase ]]; then
    GIT_EDITOR=true git -C "$worktree" rebase --continue > /dev/null
  else
    git -C "$worktree" commit -qm 'Resolve retarget conflict'
  fi
  (
    cd "$repo"
    git subrepo retarget "$prefix" --remote "$remote" --branch "$branch"
  ) > /dev/null
  is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.remote)" "$remote" \
    'resumed retarget records the new remote'
  is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.branch)" "$branch" \
    'resumed retarget records the new branch'
  is "$(git --git-dir="$remote" show "$branch:ReadMe")" "resolved-$method" \
    'resumed retarget publishes the conflict resolution'
  is "$(git --git-dir="$remote" show "$branch:local-only")" local \
    'resumed retarget preserves local contributions'
  is "$(git --git-dir="$remote" show "$branch:remote-only")" remote \
    'resumed retarget preserves incoming contributions'
  is "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" "$original" \
    'retarget never publishes to the previous upstream'
  is "$(git -C "$repo" status --porcelain)" "" 'resolved retarget leaves a clean parent'
  test-exists "!$worktree/"
done

done_testing
teardown
