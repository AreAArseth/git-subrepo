#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
subrepo-clone-bar-into-foo
repo=$OWNER/foo
before=$(git -C "$repo" rev-parse HEAD)
refs=$(git -C "$repo" show-ref)
metadata=$(cat "$repo/bar/.gitrepo")
(
  cd "$repo"
  git subrepo migrate bar --history=prefixed --dry-run
) > "$TMP/preview" 2>&1
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'migration preview preserves HEAD'
is "$(git -C "$repo" show-ref)" "$refs" 'migration preview preserves all refs'
is "$(cat "$repo/bar/.gitrepo")" "$metadata" 'migration preview preserves metadata bytes'
like "$(cat "$TMP/preview")" 'Collaborators must use' 'migration explains the compatibility transition'
(
  cd "$repo"
  git subrepo migrate bar --history=prefixed
) > /dev/null
is "$(git -C "$repo" rev-parse HEAD^1)" "$before" 'migration retains the published parent chain'
is "$(git -C "$repo" diff --name-only "$before" HEAD)" bar/.gitrepo \
  'migration changes only metadata'
is "$(git -C "$repo" config -f bar/.gitrepo --get-regexp '^subrepo\.' || true)" "" \
  'migration removes the entire legacy section'
after=$(git -C "$repo" rev-parse HEAD)
(cd "$repo" && git subrepo migrate bar) > /dev/null
is "$(git -C "$repo" rev-parse HEAD)" "$after" 'migration is idempotent'

git init -q --bare "$UPSTREAM/new.git"
(
  cd "$repo"
  mkdir local
  echo 'Initial shared content' > local/content
  git add .
  git commit -qm 'Existing directory'
  git subrepo init local -r "$UPSTREAM/new.git"
) > /dev/null
is "$(git -C "$repo" config -f local/.gitrepo subrepo-v2.state)" unpublished \
  'init records an explicit unpublished state'
is "$(git -C "$repo" config -f local/.gitrepo subrepo-v2.commit || true)" "" \
  'init does not invent an upstream ID'
(cd "$repo" && git subrepo push local) > /dev/null
is "$(git --git-dir="$UPSTREAM/new.git" show master:content)" 'Initial shared content' \
  'first push publishes to an actual initially empty repository'
is "$(git -C "$repo" config -f local/.gitrepo subrepo-v2.state)" tracking \
  'first publication transitions to tracking'

done_testing
teardown
