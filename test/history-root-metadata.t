#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
(
  cd "$OWNER/bar"
  git config -f .gitrepo subrepo.remote "$UPSTREAM/bar"
  git config -f .gitrepo subrepo.branch master
  git config -f .gitrepo subrepo.commit "$(git rev-parse HEAD)"
  git add .gitrepo
  git commit -qm 'Accidentally exported root tracking metadata'
  git branch with-metadata
  git rm -q .gitrepo
  git commit -qm 'Remove tracking metadata from upstream'
  git push -q origin master with-metadata
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" shared --history=legacy
) > /dev/null
original=$(git -C "$OWNER/bar" rev-parse with-metadata)
tip=$(git -C "$OWNER/bar" rev-parse HEAD)
before=$(git -C "$repo" rev-parse HEAD)
status=0
(cd "$repo" && git subrepo migrate shared) > "$TMP/migration" 2>&1 || status=$?
is "$status" 0 'migration accepts removed root tracking metadata'
if [[ $status == 0 ]]; then
  mapped=$(git -C "$repo" config -f shared/.gitrepo subrepo-v2.mappedCommit)
  is "$(git -C "$repo" rev-parse "$mapped^:shared")" \
    "$(git -C "$OWNER/bar" rev-parse "$original^{tree}")" \
    'historical mapped tree preserves root metadata and all other objects'
  is "$(git -C "$repo" rev-parse "$mapped:shared")" \
    "$(git -C "$OWNER/bar" rev-parse "$tip^{tree}")" \
    'mapped tip preserves the later deletion of root metadata'
  is "$(git -C "$repo" rev-list --count "$mapped")" \
    "$(git -C "$OWNER/bar" rev-list --count HEAD)" \
    'migration retains metadata-only commits'
  is "$(git -C "$repo" diff --name-only "$before" HEAD)" shared/.gitrepo \
    'migration changes only the live tracking file'
  is "$(git -C "$repo" config -f shared/.gitrepo subrepo-v2.commit)" "$tip" \
    'live tracking uses v2 and retains the original upstream identity'
  (
    cd "$OWNER/bar"
    echo incoming > incoming
    git add incoming
    git commit -qm 'Change after historical metadata cleanup'
    git push -q
    cd "$repo"
    git subrepo pull shared
    echo outgoing > shared/outgoing
    git add shared/outgoing
    git commit -qm 'Local change after migration'
    git subrepo push shared
  ) > /dev/null
  is "$(cat "$repo/shared/incoming")" incoming 'subsequent pull imports incoming content'
  is "$(git --git-dir="$UPSTREAM/bar" show master:outgoing)" outgoing \
    'subsequent push exports local changes'
  is "$(git --git-dir="$UPSTREAM/bar" ls-tree --name-only master -- .gitrepo)" "" \
    'subsequent push does not reintroduce root tracking metadata'
  is "$(git -C "$repo" status --porcelain)" "" 'round trip leaves a clean project'
fi

status=0
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" blocked -b with-metadata) > "$TMP/refused" 2>&1 || status=$?
is "$status" 1 'an upstream tip still containing root tracking metadata is refused'
like "$(cat "$TMP/refused")" 'root tracking metadata' 'tip refusal distinguishes root metadata from nesting'
is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo/blocked/map-1/)" "" \
  'tip refusal happens before writing mapped history'

done_testing
teardown
