#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo

(
  cd "$OWNER/bar"
  mkdir -p tools/.gitrepo
  echo ordinary > tools/.gitrepo/content
  git add .
  git commit -qm 'An ordinary directory named .gitrepo'
  for i in {1..40}; do
    git commit -q --allow-empty -m "Empty upstream change $i"
  done
  git push -q
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" 'nested/shared files' --history=legacy
  GIT_TRACE="$TMP/migration.trace" git subrepo migrate 'nested/shared files'
) > /dev/null
is "$(git -C "$repo" show 'HEAD:nested/shared files/tools/.gitrepo/content')" ordinary \
  'a directory named .gitrepo is not mistaken for a metadata file'
mapped=$(git -C "$repo" config -f 'nested/shared files/.gitrepo' subrepo-v2.mappedCommit)
is "$(git -C "$repo" rev-list --count "$mapped")" "$(git -C "$OWNER/bar" rev-list --count HEAD)" \
  'batch migration retains every empty upstream commit'
processes=$(grep -c 'trace: built-in:' "$TMP/migration.trace")
ok "$([[ $processes -lt 200 ]])" \
  "migration batches Git work instead of launching many processes per commit ($processes processes)"

clean=$(git -C "$OWNER/bar" rev-parse HEAD)
for kind in quoted ordinary; do
  path=ordinary
  [[ $kind != quoted ]] || path=$'unusual\npath'
  (
    cd "$OWNER/bar"
    git checkout -qb "$kind" "$clean"
    mkdir -p "$path"
    echo metadata > "$path/.gitrepo"
    git add .
    git commit -qm 'Historical nested metadata'
    git rm -qr "$path"
    git commit -qm 'Remove nested metadata from the current tree'
    git push -q origin "$kind"
    cd "$repo"
    git subrepo clone "$UPSTREAM/bar" "blocked-$kind" -b "$kind" --history=legacy
  ) > /dev/null
  before=$(git -C "$repo" rev-parse HEAD)
  status=0
  (cd "$repo" && git subrepo migrate "blocked-$kind") > "$TMP/refused" 2>&1 || status=$?
  is "$status" 1 "migration refuses deleted $kind nested metadata"
  like "$(cat "$TMP/refused")" 'nested subrepo metadata' 'historical metadata refusal explains the cause'
  is "$(git -C "$repo" for-each-ref --format='%(refname)' "refs/subrepo/blocked-$kind/map-1/")" "" \
    'unsupported history is rejected before writing any mapping refs'
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'refusal preserves the parent commit'
  is "$(git -C "$repo" status --porcelain)" "" 'refusal preserves the working tree and index'
done

done_testing
teardown
