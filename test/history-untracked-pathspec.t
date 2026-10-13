#!/usr/bin/env bash

set -e
source test/setup
use Test::More

number=0
for prefix in ':(top)shared' ':(literal)shared' 'shared[ab]'; do
  number=$((number + 1))
  repo=$OWNER/project-$number
  remote=$UPSTREAM/shared-$number
  writer=$COLLAB/shared-$number
  git clone -q "$UPSTREAM/foo" "$repo"
  git clone -q --bare "$UPSTREAM/bar" "$remote"
  git clone -q "$remote" "$writer"
  (cd "$repo" && git subrepo clone "$remote" "$prefix") > /dev/null
  printf '**/local-*\n' >> "$repo/.git/info/exclude"
  printf 'local notes\n' > "$repo/$prefix/local-notes"
  echo incoming > "$writer/incoming"
  git -C "$writer" add incoming
  git -C "$writer" commit -qm 'Non-conflicting incoming content'
  git -C "$writer" push -q
  status=0
  (cd "$repo" && git subrepo pull "$prefix") > "$TMP/operation" 2>&1 || status=$?
  is "$status" 0 "$prefix pull allows harmless ignored files"
  is "$(cat "$repo/$prefix/incoming")" incoming "$prefix pull installs incoming content"
  is "$(cat "$repo/$prefix/local-notes")" 'local notes' "$prefix pull preserves ignored notes"

  echo upstream > "$writer/local-collision"
  git -C "$writer" add local-collision
  git -C "$writer" commit -qm 'Incoming ignored-file collision'
  git -C "$writer" push -q
  echo local > "$repo/$prefix/local-collision"
  is "$(git -C "$repo" ls-files --others --ignored --exclude-standard -- ":(literal)$prefix/local-collision")" \
    "$prefix/local-collision" "$prefix collision fixture is ignored"
  before=$(git -C "$repo" rev-parse HEAD)
  index=$(git -C "$repo" write-tree)
  metadata=$(cat "$repo/$prefix/.gitrepo")
  # Pathspec magic must not hide incoming paths from overwrite protection.
  for operation in pull reclone; do
    args=(pull "$prefix" --force)
    if [[ $operation == reclone ]]; then args=(clone "$remote" "$prefix" --force); fi
    status=0
    (cd "$repo" && git subrepo "${args[@]}") > "$TMP/operation" 2>&1 || status=$?
    label="$prefix $operation"
    is "$status" 1 "$label refuses an ignored-file collision even with force"
    like "$(cat "$TMP/operation")" 'untracked or ignored.*overwritten' "$label explains the collision"
    is "$(cat "$repo/$prefix/local-collision")" local "$label preserves colliding content"
    is "$(cat "$repo/$prefix/local-notes")" 'local notes' "$label preserves harmless ignored content"
    is "$(git -C "$repo" rev-parse HEAD)" "$before" "$label preserves HEAD"
    is "$(git -C "$repo" write-tree)" "$index" "$label preserves index entries"
    is "$(cat "$repo/$prefix/.gitrepo")" "$metadata" "$label preserves tracking metadata"
  done
  rm "$repo/$prefix/local-collision"
  status=0
  (cd "$repo" && git subrepo pull "$prefix") > "$TMP/operation" 2>&1 || status=$?
  is "$status" 0 "$prefix pull succeeds after removing the collision"
  is "$(cat "$repo/$prefix/local-collision")" upstream "$prefix retry installs incoming content"
  is "$(cat "$repo/$prefix/local-notes")" 'local notes' "$prefix retry preserves harmless ignored content"
  is "$(git -C "$repo" diff --name-only; git -C "$repo" diff --cached --name-only)" "" \
    "$prefix retry leaves tracked files and index clean"
done

done_testing
teardown
