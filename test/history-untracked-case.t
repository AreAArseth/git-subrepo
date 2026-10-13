#!/usr/bin/env bash

set -e
source test/setup
use Test::More

for config in default false unset true; do
for kind in exact ancestor descendant; do
  label="$kind collision with core.ignorecase=$config"
  repo=$OWNER/$config-$kind
  remote=$UPSTREAM/$config-$kind
  writer=$COLLAB/$config-$kind
  git clone -q --bare "$UPSTREAM/bar" "$remote"
  git clone -q "$remote" "$writer"
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$remote" shared) > /dev/null
  incoming=collision.log
  local_path=COLLISION.log
  case "$kind" in
    ancestor) incoming=collision.log/child ;;
    descendant) local_path=COLLISION.log/child ;;
  esac
  mkdir -p "$(dirname "$writer/$incoming")" "$(dirname "$repo/shared/$local_path")"
  echo incoming > "$writer/$incoming"
  git -C "$writer" add "$incoming"
  git -C "$writer" commit -qm 'Incoming case-sensitive path'
  git -C "$writer" push -q
  echo local > "$repo/shared/$local_path"
  printf '*.log\n' >> "$repo/.git/info/exclude"
  echo notes > "$repo/shared/local-notes.log"
  case "$config" in
    false|true) git -C "$repo" config core.ignorecase "$config" ;;
    unset) git -C "$repo" config --unset core.ignorecase || [[ $? == 5 ]] ;;
  esac
  is "$(git -C "$repo" ls-files --others --ignored --exclude-standard -- ":(literal)shared/$local_path")" \
    "shared/$local_path" "$label fixture is ignored"
  touch "$repo/shared/case-probe"
  insensitive=false
  [[ ! -e $repo/shared/CASE-PROBE ]] || insensitive=true
  rm "$repo/shared/case-probe"
  before=$(git -C "$repo" rev-parse HEAD)
  index=$(git -C "$repo" write-tree)
  metadata=$(cat "$repo/shared/.gitrepo")
  if $insensitive; then
    for operation in pull reclone; do
      args=(pull shared --force)
      if [[ $operation == reclone ]]; then args=(clone "$remote" shared --force); fi
      status=0
      (cd "$repo" && git subrepo "${args[@]}") > "$TMP/operation" 2>&1 || status=$?
      is "$status" 1 "$label $operation is refused on a case-insensitive filesystem"
      like "$(cat "$TMP/operation")" 'untracked or ignored.*overwritten' "$label $operation explains the collision"
      is "$(git -C "$repo" rev-parse HEAD)" "$before" "$label $operation preserves HEAD"
      is "$(git -C "$repo" write-tree)" "$index" "$label $operation preserves index entries"
      is "$(cat "$repo/shared/.gitrepo")" "$metadata" "$label $operation preserves tracking metadata"
      is "$(cat "$repo/shared/$local_path")" local "$label $operation preserves colliding content"
      is "$(cat "$repo/shared/local-notes.log")" notes "$label $operation preserves harmless notes"
    done
    if [[ -d $repo/shared/COLLISION.log ]]; then
      rm "$repo/shared/COLLISION.log/child"
      rmdir "$repo/shared/COLLISION.log"
    else
      rm "$repo/shared/COLLISION.log"
    fi
    status=0
    (cd "$repo" && git subrepo pull shared) > "$TMP/operation" 2>&1 || status=$?
    is "$status" 0 "$label permits retry after removing the collision"
  else
    status=0
    (cd "$repo" && git subrepo pull shared --force) > "$TMP/operation" 2>&1 || status=$?
    is "$status" 0 "$label permits case-distinct paths on a case-sensitive filesystem"
    is "$(cat "$repo/shared/$local_path")" local "$label preserves case-distinct local content"
  fi
  is "$(cat "$repo/shared/$incoming")" incoming "$label update installs incoming content"
  is "$(cat "$repo/shared/local-notes.log")" notes "$label update preserves harmless notes"
  is "$(git -C "$repo" diff --name-only; git -C "$repo" diff --cached --name-only)" "" \
    "$label update leaves tracked files and index clean"
  is "$(git -C "$repo" ls-files --others -- 'shared/.git-subrepo-case.*')" "" \
    "$label leaves no filesystem probe"
done
done

done_testing
teardown
