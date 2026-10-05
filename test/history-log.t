#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" bar
  echo first > bar/first
  git add .
  git commit -qm 'Same subject'
  git rev-parse HEAD > "$TMP/source"
  echo second > bar/second
  git add .
  git commit -qm 'Same subject'
  git subrepo push bar
  git subrepo log bar --group-equivalent --oneline > "$TMP/grouped"
) > /dev/null
is "$(grep -c '\[local\] Same subject' "$TMP/grouped")" 2 \
  'different changes with the same subject remain separate groups'
is "$(grep -c 'Same shared change' "$TMP/grouped")" 2 \
  'each source is grouped with only its proven imported representation'

(
  cd "$OWNER/bar"
  git pull -q
  echo unrelated > unrelated
  git add .
  git commit -qm 'Same subject'
  {
    printf 'tree %s\nparent %s\n' "$(git rev-parse 'HEAD^{tree}')" "$(git rev-parse HEAD^)"
    printf 'author Someone <someone@example.invalid> 1234567890 +0000\n'
    printf 'committer Someone <someone@example.invalid> 1234567890 +0000\n'
    printf 'git-subrepo-source 1 %s 626172\n\nSame subject\n' "$(cat "$TMP/source")"
  } > "$TMP/claimed"
  claimed=$(git hash-object -t commit -w "$TMP/claimed")
  git update-ref refs/heads/master "$claimed"
  git push -q
)
before=$(git -C "$repo" rev-parse HEAD)
(cd "$repo" && git subrepo log bar --fetch --incoming --oneline) > "$TMP/incoming"
like "$(cat "$TMP/incoming")" '\[upstream\] Same subject' 'incoming log shows fetched original upstream history'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'fetching incoming log does not change parent HEAD'
is "$(git -C "$repo" status --porcelain)" "" 'incoming log preserves index and worktree'
(
  cd "$repo"
  echo pending > bar/pending
  git add bar/pending
  git commit -qm 'Pending local change'
  git subrepo status bar --log --diff > "$TMP/status-details"
)
like "$(cat "$TMP/status-details")" 'Local and incoming changes' \
  'status does not recommend pushing before incoming changes are integrated'
like "$(cat "$TMP/status-details")" 'Pending local change' 'v2 status retains local log details'
like "$(cat "$TMP/status-details")" 'Remote commits:' 'v2 status retains incoming log details'
like "$(cat "$TMP/status-details")" 'Local diff:' 'v2 status retains shared-only diff summaries'
(
  cd "$repo"
  git subrepo pull bar
  git subrepo log bar --group-equivalent --oneline > "$TMP/unverified"
) > /dev/null
mapped=$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.mappedCommit)
status=0
grep -F "${mapped:0:12} [imported] Same subject" "$TMP/unverified" > /dev/null || status=$?
is "$status" 0 'a false source claim is not collapsed into an unrelated local commit'
is "$(grep -c 'Same shared change' "$TMP/unverified")" 2 \
  'unverified provenance does not create a third equivalence group'
status=0
(cd "$repo" && git subrepo log bar --group-equivalent -- --graph) > "$TMP/options" 2>&1 || status=$?
is "$status" 1 'unsupported grouped formatting fails explicitly'
like "$(cat "$TMP/options")" 'Remove --group-equivalent' 'formatting refusal gives the supported alternative'
(cd "$repo" && git subrepo log bar -- --format=%s) > "$TMP/custom"
like "$(cat "$TMP/custom")" 'Same subject' 'ungrouped custom Git formatting is passed through'

done_testing
teardown
