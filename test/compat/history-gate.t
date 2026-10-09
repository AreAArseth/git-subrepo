#!/usr/bin/env bash

set -e
source test/setup
use Test::More

[[ -n ${GIT_SUBREPO_LEGACY_ROOT:-} && -f $GIT_SUBREPO_LEGACY_ROOT/lib/git-subrepo ]] ||
  die 'Set GIT_SUBREPO_LEGACY_ROOT to the pinned legacy source checkout'
legacy_root=$GIT_SUBREPO_LEGACY_ROOT
clone-foo-and-bar
repo=$OWNER/foo
(
  cd "$repo"
  GIT_SUBREPO_ROOT=$legacy_root "$legacy_root/lib/git-subrepo" clone "$UPSTREAM/bar" bar
  git subrepo migrate bar
) > /dev/null 2>&1
before=$(git -C "$repo" rev-parse HEAD)
metadata=$(cat "$repo/bar/.gitrepo")

for operation in fetch pull push branch clean config status; do
  args=("$operation" bar)
  [[ $operation != config ]] || args+=(remote)
  status=0
  (
    cd "$repo"
    GIT_SUBREPO_ROOT=$legacy_root "$legacy_root/lib/git-subrepo" "${args[@]}"
  ) > "$TMP/legacy-$operation" 2>&1 || status=$?
  if [[ $operation == status ]]; then
    like "$(cat "$TMP/legacy-$operation")" 'subrepo\.' \
      'legacy status reports missing old metadata (its exit status is not a reliable gate)'
  else
    isnt "$status" 0 "pinned legacy $operation refuses the migrated metadata"
  fi
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "legacy $operation does not advance parent HEAD"
  is "$(cat "$repo/bar/.gitrepo")" "$metadata" "legacy $operation does not modify migrated settings"
  is "$(git -C "$repo" status --porcelain)" "" "legacy $operation keeps project content unchanged"
done

for operation in pull clone init; do
  case "$operation" in
    pull) args=(pull bar --force --remote "$UPSTREAM/bar" --branch master) ;;
    clone) args=(clone "$UPSTREAM/bar" bar --force) ;;
    init) args=(init bar) ;;
  esac
  status=0
  (
    cd "$repo"
    GIT_SUBREPO_ROOT=$legacy_root "$legacy_root/lib/git-subrepo" "${args[@]}"
  ) > "$TMP/legacy-forced-$operation" 2>&1 || status=$?
  isnt "$status" 0 "pinned legacy $operation cannot replace the migrated subrepo"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "legacy replacement attempt preserves parent HEAD"
  is "$(git -C "$repo" status --porcelain)" "" "legacy replacement attempt preserves project files"
done

(cd "$repo" && git subrepo branch bar -F) > /dev/null
status=0
(
  cd "$repo"
  GIT_SUBREPO_ROOT=$legacy_root "$legacy_root/lib/git-subrepo" commit bar
) > "$TMP/legacy-commit" 2>&1 || status=$?
isnt "$status" 0 'pinned legacy manual commit refuses migrated metadata with a real worktree present'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'legacy manual commit preserves the parent history'
(cd "$repo" && git subrepo clean bar) > /dev/null

done_testing
teardown
