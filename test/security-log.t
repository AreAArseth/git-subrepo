#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
local_commit=$(git -C "$repo" rev-parse HEAD)
(
  cd "$OWNER/bar"
  printf 'upstream\n' > unusual
  git add unusual
  git commit -qm 'Tree change before unusual headers'
  tree=$(git rev-parse 'HEAD^{tree}')
  parent=$(git rev-parse HEAD^)
  printf 'tree %s\nparent %s\nauthor Test <test@example.invalid> 1234567890 +0000\ncommitter Test <test@example.invalid> 1234567890 +0000\ncommit %s\n\nImported unusual headers\n' \
    "$tree" "$parent" "$local_commit" > "$TMP/raw-commit"
  crafted=$(git hash-object -t commit -w "$TMP/raw-commit")
  git update-ref refs/heads/master "$crafted"
  git push -q
)
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar) > /dev/null
original=$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.commit)
mapped=$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.mappedCommit)
for group in '' --group-equivalent; do
  (cd "$repo" && git subrepo log bar $group) > "$TMP/history"
  like "$(cat "$TMP/history")" "${mapped:0:12} \\[imported\\] Imported unusual headers" \
    'an upstream commit header cannot spoof the displayed object identity'
  like "$(cat "$TMP/history")" "Original upstream commit: $original" \
    'provenance remains attached to the actual imported object'
done

done_testing
teardown
