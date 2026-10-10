#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

for mode in legacy prefixed; do
  repo=$OWNER/$mode
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar --history="$mode") > /dev/null
  for component in tmp tmp/subrepo tmp/subrepo/bar; do
    outside=$TMP/outside-$mode-${component//\//-}
    mkdir -p "$outside/subrepo/bar" "$outside/bar"
    printf 'keep\n' > "$outside/subrepo/bar/keep"
    printf 'keep\n' > "$outside/bar/keep"
    printf 'keep\n' > "$outside/keep"
    mkdir -p "$(dirname "$repo/.git/$component")"
    if [[ -d $repo/.git/$component ]]; then
      mv "$repo/.git/$component" "$TMP/saved-component"
    fi
    ln -s "$outside" "$repo/.git/$component"
    status=0
    (cd "$repo" && git subrepo clean bar) > "$TMP/refused" 2>&1 || status=$?
    isnt "$status" 0 "$mode cleanup refuses a symlink at $component"
    like "$(cat "$TMP/refused")" 'symbolic link' 'cleanup refusal identifies unsafe path'
    is "$(cat "$outside/keep" "$outside/bar/keep" "$outside/subrepo/bar/keep")" \
      $'keep\nkeep\nkeep' 'all outside content is preserved'
    rm "$repo/.git/$component"
    if [[ -d $TMP/saved-component ]]; then
      mv "$TMP/saved-component" "$repo/.git/$component"
    fi
  done
  git -C "$repo" worktree add -qb unrelated "$repo/.git/tmp/subrepo/bar"
  status=0
  (cd "$repo" && git subrepo clean bar) > "$TMP/refused" 2>&1 || status=$?
  isnt "$status" 0 "$mode refuses a different branch registered at the shared worktree path"
  test-exists "$repo/.git/tmp/subrepo/bar/Foo"
  git -C "$repo" worktree remove "$repo/.git/tmp/subrepo/bar"
done

git clone -q "$UPSTREAM/bar" "$OWNER/symlink-source"
(
  cd "$OWNER/symlink-source"
  ln -s "$TMP/tracking-target" .gitrepo
  git add .gitrepo
  git commit -qm 'Incoming symlink tracking entry'
)
git clone -q "$UPSTREAM/foo" "$OWNER/symlink-clone"
before=$(git -C "$OWNER/symlink-clone" rev-parse HEAD)
status=0
(cd "$OWNER/symlink-clone" && git subrepo clone "$OWNER/symlink-source" bar --history=legacy) \
  > "$TMP/refused" 2>&1 || status=$?
isnt "$status" 0 'legacy clone refuses incoming symlink tracking metadata'
test-exists "!$TMP/tracking-target"
is "$(git -C "$OWNER/symlink-clone" rev-parse HEAD)" "$before" 'unsafe incoming metadata cannot create a project commit'
is "$(git -C "$OWNER/symlink-clone" status --porcelain)" "" 'incoming metadata is rejected before changing the index'
git -C "$OWNER/symlink-source" update-ref refs/heads/safe HEAD^
git clone -q "$UPSTREAM/foo" "$OWNER/symlink-pull"
(cd "$OWNER/symlink-pull" && git subrepo clone "$OWNER/symlink-source" bar -b safe --history=legacy) > /dev/null
git -C "$OWNER/symlink-source" update-ref refs/heads/safe HEAD
before=$(git -C "$OWNER/symlink-pull" rev-parse HEAD)
status=0
(cd "$OWNER/symlink-pull" && git subrepo pull bar) > "$TMP/refused" 2>&1 || status=$?
isnt "$status" 0 'legacy pull also rejects incoming symlink tracking metadata before checkout'
test-exists "!$TMP/tracking-target"
is "$(git -C "$OWNER/symlink-pull" rev-parse HEAD)" "$before" 'unsafe pull preserves project HEAD'
is "$(git -C "$OWNER/symlink-pull" status --porcelain)" "" 'unsafe pull preserves the index and worktree'

git clone -q "$UPSTREAM/foo" "$OWNER/encoded"
git clone -q --bare "$UPSTREAM/bar" "$UPSTREAM/encoded.git"
(
  cd "$OWNER/encoded"
  count=0
  for directory in 'libs/.vendor' 'my library'; do
    mkdir -p "$directory"
    printf 'shared\n' > "$directory/shared"
    git add .
    git commit -qm 'Shared directory with encoded ref name'
    git subrepo init "$directory" --history=legacy --remote="$UPSTREAM/encoded.git" --branch="exported-$count"
    git subrepo branch "$directory"
    subdir=$directory
    history_mode=legacy
    encode-subdir
    git ls-tree --name-only "subrepo/$subref" > "$TMP/tree-${directory//\//-}"
    git subrepo clean "$directory"
    git subrepo push "$directory"
    git --git-dir="$UPSTREAM/encoded.git" ls-tree --name-only "exported-$count" \
      > "$TMP/pushed-${directory//\//-}"
    count=$((count + 1))
  done
) > "$TMP/encoded-log" 2>&1
for directory in 'libs/.vendor' 'my library'; do
  is "$(cat "$TMP/tree-${directory//\//-}")" shared \
    "parentless branch for '$directory' contains only shared content"
  is "$(cat "$TMP/pushed-${directory//\//-}")" shared \
    "parentless push for '$directory' publishes only shared content"
done

(
  cd "$OWNER/encoded"
  mkdir failure
  printf 'shared\n' > failure/shared
  git add .
  git commit -qm 'Subdirectory for filter failure'
  git subrepo init failure --history=legacy --remote="$UPSTREAM/encoded.git" --branch=failed
) > /dev/null
before=$(git --git-dir="$UPSTREAM/encoded.git" show-ref)
status=0
(
  git() {
    if [[ $1 == filter-branch ]]; then
      printf 'Subdirectory extraction failed\n' >&2
      return 2
    fi
    command git "$@"
  }
  export -f git
  cd "$OWNER/encoded"
  git subrepo push failure
) > "$TMP/refused" 2>&1 || status=$?
isnt "$status" 0 'subdirectory filter failure aborts publication'
like "$(cat "$TMP/refused")" 'Could not extract shared history' 'filter failure is reported explicitly'
is "$(git --git-dir="$UPSTREAM/encoded.git" show-ref)" "$before" 'failed extraction cannot publish parent history'
is "$(git -C "$OWNER/encoded" show-ref --verify refs/heads/subrepo/failure 2>/dev/null || true)" "" \
  'failed extraction does not leave a full-project branch disguised as shared history'

done_testing
teardown
