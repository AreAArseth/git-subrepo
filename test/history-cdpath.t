#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
linked=$OWNER/linked
search=$TMP/cdpath-search/deeper
mkdir -p "$search"
git init -q "$search"

run-with-cdpath() {
  local directory=$1 path=$2
  shift 2
  status=0
  (cd "$directory" && CDPATH="$path" git subrepo "$@") \
    > "$TMP/cdpath-output" 2>&1 || status=$?
}

# Both stdout from cd and lookup of an unrelated .git directory are unsafe.
run-with-cdpath "$repo" "" clone "$UPSTREAM/bar" bar
is "$status" 0 'the initial clone succeeds without CDPATH lookup'
run-with-cdpath "$repo" ".:$search" clone "$UPSTREAM/bar" another
is "$status" 0 'clone resolves its own common directory with CDPATH set'
like "$(cat "$TMP/cdpath-output")" "cloned into 'another'" 'clone reports its completed import'
test-exists "$repo/another/.gitrepo"

for path in ".:$search" "$search"; do
  run-with-cdpath "$repo" "$path" fetch bar
  is "$status" 0 'fetch ignores CDPATH when resolving its common directory'
  is "$(git -C "$repo" rev-parse refs/subrepo/bar/fetch)" \
    "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" 'fetch uses the intended repository'
  run-with-cdpath "$repo" "$path" status bar --log --diff
  is "$status" 0 'status resolves the real object directory without CDPATH lookup or output'
  like "$(cat "$TMP/cdpath-output")" "Git subrepo 'bar':" 'status renders the intended repository'
  run-with-cdpath "$repo" "$path" log bar --group-equivalent --oneline
  is "$status" 0 'grouped log resolves its real object directory with CDPATH set'
  like "$(cat "$TMP/cdpath-output")" '\[imported\] Bar' 'grouped log renders imported history'
done
is "$(find "$search/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
  'CDPATH never redirects operation files into the unrelated repository'
is "$(git -C "$search" for-each-ref --format='%(refname)')" "" \
  'CDPATH never publishes refs into the unrelated repository'
is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
  'CDPATH operations clean up the actual common directory'
is "$(git -C "$repo" status --porcelain)" "" 'CDPATH operations leave the project clean'

git -C "$repo" worktree add -q -b linked "$linked"
run-with-cdpath "$linked" "$search" fetch bar
is "$status" 0 'a linked worktree resolves its common directory with CDPATH set'
run-with-cdpath "$linked" "$search" status bar --log --diff
is "$status" 0 'a linked worktree resolves its object directory with CDPATH set'
like "$(cat "$TMP/cdpath-output")" "Git subrepo 'bar':" 'linked status renders the intended repository'

mkdir -p "$TMP/launcher/bin" "$search/bin"
ln -s "$GIT_SUBREPO_ROOT" "$TMP/tool"
ln -s ../../tool/lib/git-subrepo "$TMP/launcher/bin/git-subrepo"
for path in ".:$search" "$search"; do
  status=0
  (cd "$TMP/launcher" && CDPATH="$path" bin/git-subrepo --version) \
    > "$TMP/symlink-output" 2>&1 || status=$?
  is "$status" 0 'a relative executable symlink ignores CDPATH while resolving its target'
  is "$(cat "$TMP/symlink-output")" "$VERSION" 'relative symlink invocation prints only the version'
done

done_testing
teardown
