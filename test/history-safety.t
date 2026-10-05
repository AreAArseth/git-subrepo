#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar) > /dev/null
before=$(git -C "$repo" rev-parse HEAD)

for path in . folder/./shared .git/objects; do
  status=0
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$path") > "$TMP/refused" 2>&1 || status=$?
  isnt "$status" 0 "unsafe shared path '$path' is refused"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'path refusal preserves parent HEAD'
  is "$(git -C "$repo" status --porcelain)" "" 'path refusal preserves tracked files'
done

mkdir "$TMP/outside"
ln -s "$TMP/outside" "$repo/linked"
status=0
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" linked/shared) > "$TMP/refused" 2>&1 || status=$?
isnt "$status" 0 'a symlink ancestor cannot redirect an import outside the project'
is "$(ls -A "$TMP/outside")" "" 'symlink refusal preserves the outside directory'
rm "$repo/linked"

printf 'bar/private\n' >> "$repo/.git/info/exclude"
printf 'private content\n' > "$repo/bar/private"
status=0
(cd "$repo" && git subrepo pull bar --force) > "$TMP/refused" 2>&1 || status=$?
isnt "$status" 0 'force does not discard ignored shared files'
like "$(cat "$TMP/refused")" 'untracked or ignored' 'ignored-file refusal explains what to preserve'
is "$(cat "$repo/bar/private")" 'private content' 'ignored content is preserved exactly'
rm "$repo/bar/private"

for layout in duplicate mixed future; do
  cp "$repo/bar/.gitrepo" "$TMP/metadata"
  case "$layout" in
    duplicate) git config -f "$repo/bar/.gitrepo" --add subrepo-v2.cmdver duplicate ;;
    mixed) git config -f "$repo/bar/.gitrepo" subrepo.commit "$before" ;;
    future) git config -f "$repo/bar/.gitrepo" subrepo-v3.format 3 ;;
  esac
  git -C "$repo" add bar/.gitrepo
  git -C "$repo" commit -qm "Malformed $layout metadata"
  malformed=$(git -C "$repo" rev-parse HEAD)
  status=0
  (cd "$repo" && git subrepo push bar --force) > "$TMP/refused" 2>&1 || status=$?
  isnt "$status" 0 "$layout metadata refuses mutation even under force"
  is "$(git -C "$repo" rev-parse HEAD)" "$malformed" 'metadata refusal leaves parent HEAD unchanged'
  cp "$TMP/metadata" "$repo/bar/.gitrepo"
  git -C "$repo" add bar/.gitrepo
  git -C "$repo" commit -qm 'Restore valid live metadata'
done

printf 'local\n' > "$repo/bar/local"
git -C "$repo" add bar/local
git -C "$repo" commit -qm 'Local contribution after malformed history'
status=0
(cd "$repo" && git subrepo branch bar -F) > "$TMP/refused" 2>&1 || status=$?
isnt "$status" 0 'export validates historical metadata rather than only the current file'
like "$(cat "$TMP/refused")" 'conflicting.*cmdver' 'historical corruption is diagnosed at its actual cause'

git clone -q "$UPSTREAM/foo" "$OWNER/reclone"
(
  cd "$OWNER/reclone"
  git subrepo clone "$UPSTREAM/bar" bar
  cd "$OWNER/bar"
  echo incoming > incoming
  git add incoming
  git commit -qm 'Incoming for forced replacement'
  git push -q
  cd "$OWNER/reclone"
  git subrepo clone "$UPSTREAM/bar" bar --force
) > /dev/null
is "$(cat "$OWNER/reclone/bar/incoming")" incoming 'forced v2 reclone installs the incoming tree'
is "$(git -C "$OWNER/reclone" status --porcelain)" "" 'forced reclone leaves a clean parent'
is "$(git -C "$OWNER/reclone" show -s --format=%P HEAD | wc -w | tr -d ' ')" 2 \
  'forced reclone still attaches mapped upstream history'

(
  cd "$OWNER/reclone"
  mkdir shared-parent
  echo parent-only > shared-parent/keep
  git add shared-parent/keep
  git commit -qm 'Parent directory matching a potential glob'
  git subrepo clone "$UPSTREAM/bar" 'shared*'
  git subrepo clone "$UPSTREAM/bar" 'shared%2a'
) > /dev/null
is "$(git -C "$OWNER/reclone" show HEAD:shared-parent/keep)" parent-only \
  'literal prefix handling does not delete parent paths matching a wildcard'
first=$(git -C "$OWNER/reclone" config -f 'shared*/.gitrepo' subrepo-v2.mappedCommit)
second=$(git -C "$OWNER/reclone" config -f 'shared%2a/.gitrepo' subrepo-v2.mappedCommit)
original=$(git -C "$OWNER/reclone" config -f 'shared*/.gitrepo' subrepo-v2.commit)
is "$(git -C "$OWNER/reclone" rev-parse "refs/subrepo/shared%2a/map-1/$original")" "$first" \
  'wildcard prefix has its own encoded cache namespace'
is "$(git -C "$OWNER/reclone" rev-parse "refs/subrepo/shared%252a/map-1/$original")" "$second" \
  'literal percent-encoded prefix cannot collide with another shared namespace'

done_testing
teardown
