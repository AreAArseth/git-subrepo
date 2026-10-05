#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
(
  cd "$OWNER/bar"
  echo executable > 'run me'
  chmod +x 'run me'
  ln -s 'run me' link
  printf '\000\377\001\n' > binary
  git add .
  git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),external"
  git commit -qm 'Modes, bytes and gitlinks'
  git push -q
  cd "$OWNER/foo"
  git subrepo clone "$UPSTREAM/bar" 'shared files'
) > /dev/null
repo=$OWNER/foo
mapped=$(git -C "$repo" config -f 'shared files/.gitrepo' subrepo-v2.mappedCommit)
is "$(git -C "$repo" rev-parse "$mapped:shared files")" \
  "$(git -C "$OWNER/bar" rev-parse 'HEAD^{tree}')" 'prefixing preserves every tree entry and blob identity'
is "$(readlink "$repo/shared files/link")" 'run me' 'symlink contents survive a real import'
ok "$([[ -x "$repo/shared files/run me" ]])" 'executable mode survives import'
status=0
cmp "$repo/shared files/binary" "$OWNER/bar/binary" || status=$?
is "$status" 0 'binary bytes survive import unchanged'

(
  cd "$repo"
  git mv 'shared files/Bar' 'shared files/renamed'
  cp 'shared files/renamed' 'shared files/copied'
  chmod -x 'shared files/run me'
  git rm -q 'shared files/binary'
  git add 'shared files'
  git commit -qm 'Rename, copy, mode and deletion'
  git subrepo push 'shared files'
) > /dev/null
is "$(git --git-dir="$UPSTREAM/bar" ls-tree master 'run me' | cut -d ' ' -f1)" 100644 \
  'export preserves an executable-mode change'
is "$(git --git-dir="$UPSTREAM/bar" ls-tree master external | cut -d ' ' -f1)" 160000 \
  'export retains the gitlink rather than flattening it'
is "$(git --git-dir="$UPSTREAM/bar" ls-tree --name-only master binary Bar)" "" \
  'export preserves deletion and rename of the original paths'
is "$(git --git-dir="$UPSTREAM/bar" rev-parse master:renamed)" \
  "$(git --git-dir="$UPSTREAM/bar" rev-parse master:copied)" 'copy preserves the original blob'
is "$(git -C "$repo" status --porcelain)" "" 'space-prefixed tree round trip leaves a clean parent'

done_testing
teardown
