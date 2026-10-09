#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

for destination in incoming same-tip; do
  repo=$OWNER/project-$destination
  remote=$UPSTREAM/shared-$destination
  git clone -q "$UPSTREAM/foo" "$repo"
  git clone -q --bare "$UPSTREAM/bar" "$remote"
  (cd "$repo" && git subrepo clone "$remote" shared) > /dev/null
  git --git-dir="$remote" update-ref refs/heads/target refs/heads/master
  if [[ $destination == incoming ]]; then
    git clone -q -b target "$remote" "$OWNER/incoming"
    (
      cd "$OWNER/incoming"
      echo incoming > incoming
      git add incoming
      git commit -qm 'Incoming shared change'
      git push -q
    )
  fi

  before=$(git -C "$repo" rev-parse HEAD)
  remote_before=$(git --git-dir="$remote" show-ref)
  tip=$(git --git-dir="$remote" rev-parse target)
  status=0
  (cd "$repo" && git subrepo retarget shared -b target) > "$TMP/result" 2>&1 || status=$?
  is "$status" 0 "$destination: retarget succeeds"
  isnt "$(git -C "$repo" rev-parse HEAD)" "$before" "$destination: retarget updates parent HEAD"
  is "$(git -C "$repo" config -f shared/.gitrepo subrepo-v2.branch)" target \
    "$destination: retarget records the selected branch"
  is "$(git -C "$repo" config -f shared/.gitrepo subrepo-v2.commit)" "$tip" \
    "$destination: retarget records the shared tip"
  if [[ $destination == incoming ]]; then
    is "$(cat "$repo/shared/incoming")" incoming 'incoming-only retarget imports shared content'
  fi
  is "$(git --git-dir="$remote" show-ref)" "$remote_before" "$destination: no push was needed"
  is "$(git -C "$repo" status --porcelain)" "" "$destination: parent is clean"
  like "$(cat "$TMP/result")" "Retargeted and synchronized 'shared/'" \
    "$destination: a completed retarget reports success"
  unlike "$(cat "$TMP/result")" 'no changes made' \
    "$destination: a no-op push does not hide the completed retarget"

  before=$(git -C "$repo" rev-parse HEAD)
  (cd "$repo" && git subrepo retarget shared -b target) > "$TMP/repeat" 2>&1
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$destination: repeated retarget preserves HEAD"
  is "$(git --git-dir="$remote" show-ref)" "$remote_before" "$destination: repeated retarget preserves upstream"
  like "$(cat "$TMP/repeat")" 'no changes made' "$destination: a whole-operation no-op is reported"
  unlike "$(cat "$TMP/repeat")" 'Retargeted and synchronized' \
    "$destination: a whole-operation no-op is not reported as a change"
done

done_testing
teardown
