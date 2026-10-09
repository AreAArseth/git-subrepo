#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
prefix='shared files'
(
  cd "$OWNER/bar"
  echo executable > runner
  chmod +x runner
  echo retained > retained
  ln -s retained link
  git add .
  git commit -qm 'Shared replacement fixture'
  git push -q
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" "$prefix"
) > /dev/null
upstream=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
mapped=$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.mappedCommit)
echo unrelated > "$repo/parent-only"
git -C "$repo" add parent-only
git -C "$repo" commit -qm 'Unrelated parent content'
outside=$(git -C "$repo" ls-tree HEAD | grep -v $'\tshared files$')

for change in content mode deletion addition symlink; do
  (
    cd "$repo"
    case "$change" in
      content) echo local > "$prefix/retained" ;;
      mode) chmod -x "$prefix/runner" ;;
      deletion) git rm -q "$prefix/retained" ;;
      addition) echo local > "$prefix/parent-added" ;;
      symlink) rm "$prefix/link"; ln -s runner "$prefix/link" ;;
    esac
    git add "$prefix"
    git commit -qm "Parent $change edit"
  )
  before=$(git -C "$repo" rev-parse HEAD)
  (cd "$repo" && git subrepo pull "$prefix") > /dev/null
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$change: ordinary pull preserves the committed edit"
  status=0
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix") > "$TMP/refused" 2>&1 || status=$?
  isnt "$status" 0 "$change: clone without force refuses replacement"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$change: refused clone preserves HEAD"

  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix" --force) > "$TMP/reclone"
  status=0
  git -C "$repo" diff --quiet "$upstream" "HEAD:$prefix" -- . ':(exclude).gitrepo' || status=$?
  is "$status" 0 "$change: explicit force restores the entire upstream tree excluding tracking metadata"
  is "$(git -C "$repo" rev-parse HEAD^1)" "$before" "$change: replacement preserves parent ancestry"
  is "$(git -C "$repo" rev-parse HEAD^2)" "$mapped" "$change: replacement attaches mapped ancestry"
  is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.parent)" "$before" \
    "$change: replacement resets the export boundary"
  is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.commit)" "$upstream" \
    "$change: replacement retains the unchanged upstream tip"
  is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.mappedCommit)" "$mapped" \
    "$change: replacement retains valid mapped metadata"
  is "$(git -C "$repo" ls-tree HEAD | grep -v $'\tshared files$')" "$outside" \
    "$change: unrelated parent entries remain identical"
  is "$(git -C "$repo" status --porcelain)" "" "$change: replacement leaves a clean parent"
  before=$(git -C "$repo" rev-parse HEAD)
  is "$(cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix" --force)" \
    "Subrepo '$prefix' is up to date." "$change: repeated force is a no-op"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$change: repeated force creates no commit"
done

echo '; Parent tracking annotation' >> "$repo/$prefix/.gitrepo"
git -C "$repo" add "$prefix/.gitrepo"
git -C "$repo" commit -qm 'Tracking annotation only'
before=$(git -C "$repo" rev-parse HEAD)
is "$(cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix" --force)" \
  "Subrepo '$prefix' is up to date." 'tracking metadata is excluded from content parity'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'metadata-only differences do not trigger replacement'

# A squash keeps identical files but drops the imported second-parent history.
base=$(git -C "$repo" rev-list --max-parents=0 --first-parent HEAD)
(
  cd "$repo"
  git checkout -qb collapsed "$base"
  git merge -q --squash master
  git commit -qm 'Collapsed shared import'
) > /dev/null
status=0
git -C "$repo" merge-base --is-ancestor "$mapped" HEAD || status=$?
is "$status" 1 'squash fixture really loses mapped ancestry despite identical shared files'
before=$(git -C "$repo" rev-parse HEAD)
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix" --force) > /dev/null
is "$(git -C "$repo" rev-parse HEAD^1)" "$before" 'force reconnects identical content with unhealthy history'
is "$(git -C "$repo" rev-parse HEAD^2)" "$mapped" 'force restores the missing mapped ancestry'
is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.parent)" "$before" \
  'force restores the synchronization boundary after a squash'
is "$(git -C "$repo" rev-parse "$mapped:$prefix")" \
  "$(git --git-dir="$UPSTREAM/bar" rev-parse 'master^{tree}')" 'mapped history preserves the upstream tree exactly'

(
  cd "$repo"
  git subrepo branch "$prefix" -F
) > /dev/null
is "$(git -C "$repo" rev-parse 'subrepo/shared%20files^{tree}')" \
  "$(git --git-dir="$UPSTREAM/bar" rev-parse 'master^{tree}')" 'branch exports only restored shared content'
(
  cd "$repo"
  git subrepo clean "$prefix"
  git subrepo push "$prefix"
) > /dev/null
is "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" "$upstream" \
  'push after replacement does not republish discarded parent edits'
(
  cd "$repo"
  echo outgoing > "$prefix/outgoing"
  git add "$prefix/outgoing"
  git commit -qm 'Contribution after replacement'
  git subrepo push "$prefix"
  cd "$OWNER/bar"
  git pull -q
  echo incoming > incoming
  git add incoming
  git commit -qm 'Incoming after replacement'
  git push -q
  cd "$repo"
  git subrepo pull "$prefix"
) > /dev/null
is "$(git --git-dir="$UPSTREAM/bar" show master:outgoing)" outgoing 'new contributions still push successfully'
is "$(cat "$repo/$prefix/incoming")" incoming 'new upstream changes still pull successfully'
is "$(git --git-dir="$UPSTREAM/bar" ls-tree --name-only master .gitrepo parent-only parent-added)" "" \
  'push excludes tracking metadata, unrelated files and discarded additions'
is "$(git -C "$repo" ls-tree HEAD | grep -v $'\tshared files$')" "$outside" \
  'subsequent operations preserve unrelated parent content'
is "$(git -C "$repo" status --porcelain)" "" 'subsequent operations leave a clean parent'
status=0
git -C "$repo" fsck --no-reflogs > "$TMP/fsck" 2>&1 || status=$?
is "$status" 0 'replacement and subsequent operations leave valid Git objects'

done_testing
teardown
