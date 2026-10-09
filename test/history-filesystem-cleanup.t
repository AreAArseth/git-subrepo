#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo

# Run on the fixture filesystem selected by TMPDIR, including real NFS.
run-operation() {
  status=0
  (cd "$repo" && git subrepo "$@") > "$TMP/operation" 2>&1 || status=$?
}

assert-cleanup() {
  is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
    "$1 removes operation directories and process locks"
  is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo-operation-lock)" "" \
    "$1 releases the durable writer lease"
}

run-operation clone "$UPSTREAM/bar" bar
is "$status" 0 'clone succeeds through filesystem cleanup'
like "$(cat "$TMP/operation")" "cloned into 'bar'" 'clone reports the completed import'
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.commit)" \
  "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" 'clone records the upstream tip'
is "$(cat "$repo/bar/Bar")" "$(git --git-dir="$UPSTREAM/bar" show master:Bar)" \
  'clone imports the upstream content'
assert-cleanup clone

before=$(git -C "$repo" rev-parse HEAD)
index=$(git -C "$repo" hash-object .git/index)
refs=$(git -C "$repo" for-each-ref --format='%(refname) %(objectname)')
for reader in status log; do
  run-operation "$reader" bar
  is "$status" 0 "$reader succeeds through reader cleanup"
  if [[ $reader == status ]]; then
    like "$(cat "$TMP/operation")" "Git subrepo 'bar':" 'status renders the shared repository'
  else
    like "$(cat "$TMP/operation")" '\[imported\] Bar' 'log renders the imported shared history'
  fi
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$reader preserves HEAD"
  is "$(git -C "$repo" hash-object .git/index)" "$index" "$reader preserves the index"
  is "$(git -C "$repo" for-each-ref --format='%(refname) %(objectname)')" "$refs" \
    "$reader preserves all refs"
  assert-cleanup "$reader"
done

(
  cd "$OWNER/bar"
  echo incoming > incoming
  git add incoming
  git commit -qm 'Incoming filesystem change'
  git push -q
)
run-operation fetch bar
is "$status" 0 'fetch succeeds through writer cleanup'
is "$(git -C "$repo" rev-parse refs/subrepo/bar/fetch)" \
  "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" 'fetch records the new upstream tip'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'fetch does not integrate the new content'
assert-cleanup fetch

run-operation pull bar
is "$status" 0 'pull succeeds through writer cleanup'
is "$(cat "$repo/bar/incoming")" incoming 'pull integrates the incoming content'
assert-cleanup pull

echo outgoing > "$repo/bar/outgoing"
git -C "$repo" add bar/outgoing
git -C "$repo" commit -qm 'Outgoing filesystem change'
run-operation push bar
is "$status" 0 'push succeeds through writer cleanup'
is "$(git --git-dir="$UPSTREAM/bar" show master:outgoing)" outgoing \
  'push publishes the outgoing content'
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.commit)" \
  "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" 'push records the published tip'
assert-cleanup push

before=$(git -C "$repo" rev-parse HEAD)
run-operation fetch missing
is "$status" 1 'an invalid subrepo still fails rather than reporting success'
like "$(cat "$TMP/operation")" "No 'missing/\\.gitrepo' file" 'the original operation failure is reported'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'failed fetch preserves HEAD'
assert-cleanup 'failed fetch'
is "$(git -C "$repo" status --porcelain)" "" 'completed operations leave a clean project'

done_testing
teardown
