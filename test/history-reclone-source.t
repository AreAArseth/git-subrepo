#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
git clone -q --bare "$UPSTREAM/bar" "$UPSTREAM/alternate"
(
  cd "$OWNER/bar"
  git checkout -qb incoming
  echo alternate > alternate
  git add alternate
  git commit -qm 'Alternate branch content'
  git push -q origin incoming
  git checkout -q master
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" bar
) > /dev/null
(
  cd "$OWNER/bar"
  echo incoming > incoming
  git add incoming
  git commit -qm 'Incoming source update'
  git push -q
)

before=$(git -C "$repo" rev-parse HEAD)
refs=$(git -C "$repo" show-ref | git hash-object --stdin)
metadata=$(git hash-object "$repo/bar/.gitrepo")
for selection in remote remote-same-branch remote-other-branch branch; do
  remote=$UPSTREAM/alternate
  options=()
  case "$selection" in
    remote-same-branch) options=(--branch master) ;;
    remote-other-branch) options=(--branch incoming) ;;
    branch) remote=$UPSTREAM/bar; options=(--branch incoming) ;;
  esac
  status=0
  (cd "$repo" && git subrepo clone "$remote" bar --force "${options[@]}") \
    > "$TMP/refused" 2>&1 || status=$?
  isnt "$status" 0 "$selection replacement is explicitly refused"
  like "$(cat "$TMP/refused")" 'git subrepo retarget' 'refusal gives retarget guidance'
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'refusal preserves parent HEAD'
  is "$(git -C "$repo" show-ref | git hash-object --stdin)" "$refs" 'refusal preserves refs without fetching'
  is "$(git hash-object "$repo/bar/.gitrepo")" "$metadata" 'refusal preserves tracking metadata'
  is "$(git -C "$repo" status --porcelain)" "" 'refusal preserves a clean parent'
done

(cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar --force --branch master) > /dev/null
is "$(cat "$repo/bar/incoming")" incoming 'same source and explicit recorded branch install incoming content'
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.remote)" "$UPSTREAM/bar" \
  'same-source reclone retains the recorded remote'
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.branch)" master \
  'same-source reclone retains the recorded branch'
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.commit)" \
  "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" 'reclone records the incoming upstream commit'
mapped=$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.mappedCommit)
is "$(git -C "$repo" rev-parse HEAD^2)" "$mapped" 'reclone attaches mapped upstream ancestry'
is "$(git -C "$repo" status --porcelain)" "" 'same-source reclone leaves a clean parent'
before=$(git -C "$repo" rev-parse HEAD)
is "$(cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar --force)" \
  "Subrepo 'bar' is up to date." 'same-source reclone without a branch remains supported'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'up-to-date reclone makes no commit'

done_testing
teardown
