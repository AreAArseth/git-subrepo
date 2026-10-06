#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

for destination in unchanged advanced new; do
  for edits in parent worktree both; do
    repo=$OWNER/$destination-$edits
    remote=$UPSTREAM/$destination-$edits
    git clone -q "$UPSTREAM/foo" "$repo"
    git clone -q --bare "$UPSTREAM/bar" "$remote"
    (
      cd "$repo"
      git subrepo clone "$remote" shared
      git subrepo branch shared
    ) > /dev/null
    worktree=$repo/.git/tmp/subrepo/shared
    if [[ $destination != new ]]; then
      git --git-dir="$remote" update-ref refs/heads/target refs/heads/master
    fi
    if [[ $destination == advanced ]]; then
      git clone -q -b target "$remote" "$OWNER/incoming-$edits"
      (
        cd "$OWNER/incoming-$edits"
        echo incoming > incoming
        git add .
        git commit -qm 'Incoming shared change'
        git push -q
      )
    fi
    if [[ $edits != worktree ]]; then
      echo parent > "$repo/shared/parent"
      git -C "$repo" add shared/parent
      git -C "$repo" commit -qm 'Newer parent contribution'
    fi
    if [[ $edits != parent ]]; then
      echo worktree > "$worktree/manual"
      git -C "$worktree" add manual
      git -C "$worktree" commit -qm 'Manual shared contribution'
    fi
    before=$(git -C "$repo" rev-parse HEAD)
    shared_before=$(git -C "$worktree" rev-parse HEAD)
    remote_before=$(git --git-dir="$remote" show-ref)
    refs_before=$(git -C "$repo" show-ref)
    objects_before=$(git -C "$repo" count-objects -v)
    (cd "$repo" && git subrepo retarget shared -b target --dry-run) > "$TMP/preview"
    like "$(cat "$TMP/preview")" 'Preview only: the remote was checked' 'retarget preview explains its boundary'
    is "$(git -C "$repo" show-ref)" "$refs_before" 'preview changes no project refs'
    is "$(git -C "$repo" count-objects -v)" "$objects_before" 'preview creates no Git objects'
    is "$(git -C "$repo" status --porcelain)" "" 'preview changes no project files'
    is "$(git --git-dir="$remote" show-ref)" "$remote_before" 'preview never publishes'
    status=0
    (cd "$repo" && git subrepo retarget shared -b target) > "$TMP/retarget" 2>&1 || status=$?
    if [[ $edits == both ]]; then
      is "$status" 1 "$destination: simultaneous parent/worktree edits stop safely"
      like "$(cat "$TMP/retarget")" 'Both.*shared.*worktree' 'refusal explains the two copies'
      is "$(git -C "$repo" rev-parse HEAD)" "$before" 'refusal preserves parent HEAD'
      is "$(git -C "$worktree" rev-parse HEAD)" "$shared_before" 'refusal preserves worktree HEAD'
      is "$(git --git-dir="$remote" show-ref)" "$remote_before" 'refusal does not publish'
      is "$(cat "$repo/shared/parent")" parent 'parent contribution is preserved'
      is "$(cat "$worktree/manual")" worktree 'worktree contribution is preserved'
    else
      is "$status" 0 "$destination: retarget accepts $edits-only contributions"
      file=parent
      [[ $edits != worktree ]] || file=manual
      is "$(git --git-dir="$remote" show "target:$file")" "$edits" \
        'retarget publishes the contribution rather than replacing it'
      is "$(cat "$repo/shared/$file")" "$edits" 'parent retains the contribution'
      if [[ $destination == advanced ]]; then
        is "$(cat "$repo/shared/incoming")" incoming 'incoming content is retained too'
      fi
      is "$(git -C "$repo" status --porcelain)" "" 'retarget leaves a clean parent'
      before=$(git -C "$repo" rev-parse HEAD)
      remote_before=$(git --git-dir="$remote" show-ref)
      (cd "$repo" && git subrepo retarget shared -b target) > "$TMP/repeat" 2>&1
      is "$(git -C "$repo" rev-parse HEAD)" "$before" 'identical retarget leaves parent HEAD unchanged'
      is "$(git --git-dir="$remote" show-ref)" "$remote_before" 'identical retarget leaves upstream unchanged'
      like "$(cat "$TMP/repeat")" 'no changes made' 'no-op reports that nothing changed'
    fi
  done
done

repo=$OWNER/unfinished
git clone -q "$UPSTREAM/foo" "$repo"
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" shared
  git subrepo branch shared
) > /dev/null
worktree=$repo/.git/tmp/subrepo/shared
before=$(git -C "$repo" rev-parse HEAD)
remote_before=$(git --git-dir="$UPSTREAM/bar" show-ref)
echo unfinished >> "$worktree/ReadMe"
status=0
(cd "$repo" && git subrepo retarget shared -b master --force) > "$TMP/unfinished" 2>&1 || status=$?
is "$status" 1 'even force refuses a dirty worktree before retarget'
like "$(cat "$TMP/unfinished")" 'unfinished changes' 'unfinished work is named, not overwritten'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'dirty worktree refusal preserves parent HEAD'
is "$(git --git-dir="$UPSTREAM/bar" show-ref)" "$remote_before" 'dirty worktree refusal never publishes'
like "$(cat "$worktree/ReadMe")" unfinished 'dirty worktree contents remain intact'

repo=$OWNER/fresh-retarget
git clone -q "$OWNER/unchanged-parent" "$repo"
before=$(git -C "$repo" rev-parse HEAD)
(cd "$repo" && git subrepo retarget shared -b target) > "$TMP/fresh-retarget"
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'identical retarget is a no-op in a fresh parent clone too'
like "$(cat "$TMP/fresh-retarget")" 'no changes made' 'fresh clone reports no-op after fetching original history'

done_testing
teardown
