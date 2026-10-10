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

  worktree=$repo/.git/tmp/subrepo/bar
  git -C "$repo" worktree add -q --detach "$worktree" HEAD
  before=$(git -C "$repo" rev-parse HEAD)
  status=0
  (cd "$repo" && git subrepo clean bar --force) > "$TMP/refused" 2>&1 || status=$?
  is "$status" 1 "$mode refuses a foreign detached worktree even with force"
  like "$(cat "$TMP/refused")" 'does not belong' 'detached refusal explains the ownership boundary'
  test-exists "$worktree/Foo"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'detached refusal preserves project HEAD'
  if [[ -d $worktree ]]; then git -C "$repo" worktree remove "$worktree"; fi

  (cd "$repo" && git subrepo branch bar) > /dev/null
  git -C "$worktree" checkout -qb rebase-target
  printf 'incoming\n' > "$worktree/Bar"
  git -C "$worktree" add Bar
  git -C "$worktree" commit -qm 'Incoming side of a real rebase'
  git -C "$worktree" checkout -q subrepo/bar
  printf 'local\n' > "$worktree/Bar"
  git -C "$worktree" add Bar
  git -C "$worktree" commit -qm 'Local side of a real rebase'
  status=0
  git -C "$worktree" rebase rebase-target > "$TMP/rebase" 2>&1 || status=$?
  is "$status" 1 "$mode fixture stops in a real conflicted rebase"
  status=0
  (cd "$repo" && git subrepo status bar) > "$TMP/rebase-status" 2>&1 || status=$?
  is "$status" 0 "$mode recognizes the expected branch during its detached rebase"
  git -C "$worktree" rebase --abort > /dev/null 2>&1
  (cd "$repo" && git subrepo clean bar) > /dev/null
done

for operation in branch clean; do
  for component in subrepo-owners subrepo-owners/tools subrepo-owners/tools/bar; do
    label=$operation-${component//\//-}
    repo=$OWNER/ownership-$label
    git clone -q "$UPSTREAM/foo" "$repo"
    (cd "$repo" && git subrepo clone "$UPSTREAM/bar" tools/bar) > /dev/null
    outside=$TMP/outside-$label
    mkdir -p "$outside/tools"
    case "$component" in
      subrepo-owners) target=$outside/tools/bar; link=$outside ;;
      subrepo-owners/tools) target=$outside/bar; link=$outside ;;
      subrepo-owners/tools/bar) target=$outside/owner; link=$target ;;
    esac
    if [[ $operation == clean || $component == subrepo-owners/tools/bar ]]; then
      printf '%s\n\n' "$(git -C "$repo" rev-parse --show-toplevel)" > "$target"
      cp "$target" "$TMP/original-owner"
    fi
    mkdir -p "$(dirname "$repo/.git/$component")"
    ln -s "$link" "$repo/.git/$component"
    before=$(git -C "$repo" rev-parse HEAD)
    status=0
    (cd "$repo" && git subrepo "$operation" tools/bar) > "$TMP/refused" 2>&1 || status=$?
    is "$status" 1 "$operation refuses redirected ownership records at $component"
    like "$(cat "$TMP/refused")" 'symbolic link' 'ownership refusal identifies unsafe paths'
    if [[ $operation == clean || $component == subrepo-owners/tools/bar ]]; then
      unchanged=0
      cmp "$target" "$TMP/original-owner" > /dev/null 2>&1 || unchanged=$?
      is "$unchanged" 0 'outside ownership content is preserved byte for byte'
    else
      test-exists "!$target"
    fi
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'ownership refusal preserves project HEAD'
    is "$(git -C "$repo" status --porcelain)" "" 'ownership refusal preserves project files'
  done
done

repo=$OWNER/ownership-directory
git clone -q "$UPSTREAM/foo" "$repo"
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" tools/bar) > /dev/null
mkdir -p "$repo/.git/subrepo-owners/tools/bar"
status=0
(cd "$repo" && git subrepo branch tools/bar) > "$TMP/refused" 2>&1 || status=$?
is "$status" 1 'a directory cannot be used as an ownership record'
like "$(cat "$TMP/refused")" 'regular file' 'nonregular ownership records are diagnosed'
is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/heads/subrepo/tools/bar)" "" \
  'invalid ownership records are refused before creating a shared branch'
test-exists "!$repo/.git/tmp/subrepo/tools/bar/"

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
