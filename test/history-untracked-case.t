#!/usr/bin/env bash

set -e
source test/setup
use Test::More

for kind in exact ancestor descendant; do
  repo=$OWNER/$kind
  remote=$UPSTREAM/$kind
  writer=$COLLAB/$kind
  git clone -q --bare "$UPSTREAM/bar" "$remote"
  git clone -q "$remote" "$writer"
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$remote" shared) > /dev/null
  incoming=collision
  local_path=COLLISION
  case "$kind" in
    ancestor) incoming=collision/child ;;
    descendant) local_path=COLLISION/child ;;
  esac
  mkdir -p "$(dirname "$writer/$incoming")" "$(dirname "$repo/shared/$local_path")"
  echo incoming > "$writer/$incoming"
  git -C "$writer" add "$incoming"
  git -C "$writer" commit -qm 'Incoming case-sensitive path'
  git -C "$writer" push -q
  echo local > "$repo/shared/$local_path"
  printf '/shared/COLLISION\n' >> "$repo/.git/info/exclude"
  touch "$repo/.git/case-probe"
  insensitive=false
  [[ ! -e $repo/.git/CASE-PROBE ]] || insensitive=true
  before=$(git -C "$repo" rev-parse HEAD)
  index=$(git -C "$repo" write-tree)
  status=0
  (cd "$repo" && git subrepo pull shared --force) > "$TMP/operation" 2>&1 || status=$?
  if $insensitive; then
    is "$status" 1 "$kind collision is refused on a case-insensitive filesystem"
    like "$(cat "$TMP/operation")" 'untracked or ignored.*overwritten' "$kind refusal explains the collision"
    is "$(git -C "$repo" rev-parse HEAD)" "$before" "$kind collision preserves HEAD"
    is "$(git -C "$repo" write-tree)" "$index" "$kind collision preserves index entries"
  else
    is "$status" 0 "$kind case-distinct paths are allowed on a case-sensitive filesystem"
    is "$(cat "$repo/shared/$incoming")" incoming "$kind update installs the case-distinct file"
  fi
  is "$(cat "$repo/shared/$local_path")" local "$kind update preserves the case-distinct local content"
done

done_testing
teardown
