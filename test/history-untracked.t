#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
prefix='shared files'
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix") > /dev/null

run-operation() {
  status=0
  (cd "$repo" && git subrepo "$@") > "$TMP/operation" 2>&1 || status=$?
}

add-untracked() {
  mkdir -p "$repo/$prefix/cache" "$repo/$prefix/scratch"
  printf 'ignored cache\n' > "$repo/$prefix/cache/output"
  printf 'untracked notes\n' > "$repo/$prefix/scratch/notes"
  printf 'unusual name\n' > "$repo/$prefix/"$'notes\n[*]'
  printf 'outside content\n' > "$repo/parent-untracked"
  ln -s ../parent-untracked "$repo/$prefix/local-link"
  printf '/%s/cache/\n' "$prefix" >> "$repo/.git/info/exclude"
}

assert-preserved() {
  local label=$1
  is "$(cat "$repo/$prefix/cache/output")" 'ignored cache' "$label preserves ignored files"
  is "$(cat "$repo/$prefix/scratch/notes")" 'untracked notes' "$label preserves untracked files"
  is "$(cat "$repo/$prefix/"$'notes\n[*]')" 'unusual name' "$label preserves literal unusual filenames"
  is "$(readlink "$repo/$prefix/local-link")" ../parent-untracked "$label preserves untracked symlinks"
  is "$(cat "$repo/parent-untracked")" 'outside content' "$label preserves project-only files"
  is "$(git -C "$repo" diff --name-only; git -C "$repo" diff --cached --name-only)" "" \
    "$label leaves tracked files and index clean"
}

add-untracked
(
  cd "$OWNER/bar"
  echo incoming > incoming
  git add incoming
  git commit -qm 'Non-conflicting incoming content'
  git push -q
)
run-operation pull "$prefix"
is "$status" 0 'pull allows non-conflicting untracked and ignored files'
is "$(cat "$repo/$prefix/incoming")" incoming 'pull installs the actual incoming change'
assert-preserved pull

echo outgoing > "$repo/$prefix/outgoing"
git -C "$repo" add "$prefix/outgoing"
git -C "$repo" commit -qm 'Committed outgoing content'
run-operation push "$prefix"
is "$status" 0 'push allows non-conflicting untracked and ignored files'
is "$(git --git-dir="$UPSTREAM/bar" show master:outgoing)" outgoing 'push publishes committed content'
is "$(git --git-dir="$UPSTREAM/bar" ls-tree -r --name-only master -- cache scratch local-link parent-untracked)" "" \
  'push does not publish untracked or ignored content'
assert-preserved push

run-operation branch "$prefix" --force
is "$status" 0 'branch allows project untracked files'
worktree=$repo/.git/tmp/subrepo/shared%20files
echo unfinished > "$worktree/untracked"
run-operation clean "$prefix"
is "$status" 1 'cleanup still refuses untracked files in the temporary worktree'
is "$(cat "$worktree/untracked")" unfinished 'refused cleanup preserves temporary worktree content'
rm "$worktree/untracked"
printf '/ignored\n' >> "$repo/.git/info/exclude"
echo unfinished > "$worktree/ignored"
run-operation clean "$prefix"
is "$status" 1 'cleanup still refuses ignored files in the temporary worktree'
is "$(cat "$worktree/ignored")" unfinished 'refused cleanup preserves ignored worktree content'
rm "$worktree/ignored"
echo manual > "$worktree/manual"
git -C "$worktree" add manual
git -C "$worktree" commit -qm 'Manual shared contribution'
run-operation commit "$prefix"
is "$status" 0 'commit allows non-conflicting project untracked files'
is "$(cat "$repo/$prefix/manual")" manual 'commit imports the manual shared contribution'
assert-preserved commit

run-operation clone "$UPSTREAM/bar" "$prefix" --force
is "$status" 0 'forced reclone allows harmless untracked files'
is "$([[ ! -e $repo/$prefix/manual ]] && echo removed)" removed 'forced reclone replaces committed shared changes'
assert-preserved reclone
run-operation retarget "$prefix" -b target
is "$status" 0 'retarget allows harmless untracked files'
is "$(git --git-dir="$UPSTREAM/bar" show target:outgoing)" outgoing 'retarget synchronizes the destination'
assert-preserved retarget

for operation in init migrate; do
  repo=$OWNER/$operation
  git clone -q "$UPSTREAM/foo" "$repo"
  if [[ $operation == init ]]; then
    mkdir "$repo/$prefix"
    echo tracked > "$repo/$prefix/tracked"
    git -C "$repo" add "$prefix/tracked"
    git -C "$repo" commit -qm 'Existing shared directory'
  else
    (cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix" --history=legacy) > /dev/null
  fi
  add-untracked
  run-operation "$operation" "$prefix"
  is "$status" 0 "$operation allows harmless untracked files"
  is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.history)" prefixed \
    "$operation records prefixed history"
  assert-preserved "$operation"
done

for kind in exact ancestor descendant symlink nested-repo unusual; do
  for visibility in untracked ignored; do
    repo=$OWNER/collision-$kind-$visibility
    remote=$UPSTREAM/collision-$kind-$visibility
    writer=$COLLAB/collision-$kind-$visibility
    git clone -q --bare "$UPSTREAM/bar" "$remote"
    git clone -q "$remote" "$writer"
    git clone -q "$UPSTREAM/foo" "$repo"
    prefix='shared*'
    (cd "$repo" && git subrepo clone "$remote" "$prefix") > /dev/null
    incoming=collision
    local_path=collision
    case "$kind" in
      ancestor|symlink|nested-repo) incoming=collision/child ;;
      descendant) local_path=collision/child ;;
      unusual) incoming=$'collision\n[*]'; local_path=$incoming ;;
    esac
    mkdir -p "$(dirname "$writer/$incoming")" "$(dirname "$repo/$prefix/$local_path")"
    echo upstream > "$writer/$incoming"
    git -C "$writer" add "$incoming"
    git -C "$writer" commit -qm 'Incoming path collision'
    git -C "$writer" push -q
    if [[ $kind == symlink ]]; then
      mkdir "$TMP/outside-$visibility"
      echo local > "$TMP/outside-$visibility/child"
      ln -s "$TMP/outside-$visibility" "$repo/$prefix/collision"
    elif [[ $kind == nested-repo ]]; then
      git init -q "$repo/$prefix/collision"
      echo local > "$repo/$prefix/collision/child"
      git -C "$repo/$prefix/collision" add child
      git -C "$repo/$prefix/collision" commit -qm 'Independent nested repository'
      local_path=collision/child
    else
      echo local > "$repo/$prefix/$local_path"
    fi
    if [[ $visibility == ignored ]]; then
      printf '/%s/*\n' "$prefix" >> "$repo/.git/info/exclude"
    fi
    before=$(git -C "$repo" rev-parse HEAD)
    index=$(git -C "$repo" write-tree)
    metadata=$(cat "$repo/$prefix/.gitrepo")
    for operation in pull reclone; do
      args=(pull "$prefix" --force)
      if [[ $operation == reclone ]]; then args=(clone "$remote" "$prefix" --force); fi
      run-operation "${args[@]}"
      label="$kind $visibility $operation"
      is "$status" 1 "$label refuses an overlapping untracked path"
      like "$(cat "$TMP/operation")" 'untracked or ignored.*overwritten' "$label explains the collision"
      is "$(git -C "$repo" rev-parse HEAD)" "$before" "$label preserves HEAD"
      is "$(git -C "$repo" write-tree)" "$index" "$label preserves index entries"
      is "$(cat "$repo/$prefix/.gitrepo")" "$metadata" "$label preserves tracking metadata"
      content=$repo/$prefix/$local_path
      if [[ $kind == symlink ]]; then content=$TMP/outside-$visibility/child; fi
      is "$(cat "$content")" local "$label preserves local contents"
    done
  done
done

repo=$OWNER/retry
prefix=shared
git clone -q "$UPSTREAM/foo" "$repo"
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix") > /dev/null
add-untracked
mkdir "$TMP/hooks"
printf '#!/bin/sh\nexit 1\n' > "$TMP/hooks/pre-commit"
chmod +x "$TMP/hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hooks"
(
  cd "$OWNER/bar"
  git pull -q
  echo recovered > recovered
  git add recovered
  git commit -qm 'Incoming content for interrupted integration'
  git push -q
)
before=$(git -C "$repo" rev-parse HEAD)
run-operation pull "$prefix"
is "$status" 1 'commit-hook failure interrupts integration with harmless untracked files'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'failed integration preserves HEAD'
assert-preserved rollback
echo local > "$repo/$prefix/recovered"
printf '/shared/recovered\n' >> "$repo/.git/info/exclude"
git -C "$repo" config --unset core.hooksPath
run-operation pull "$prefix"
is "$status" 1 'recovery refuses an ignored file colliding with the prepared tree'
is "$(cat "$repo/$prefix/recovered")" local 'refused recovery preserves the colliding file'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'refused recovery preserves HEAD'
rm "$repo/$prefix/recovered"
run-operation pull "$prefix"
is "$status" 0 'recovery completes with harmless untracked files'
is "$(cat "$repo/$prefix/recovered")" recovered 'recovery installs the prepared content'
assert-preserved recovery

repo=$OWNER/rollback-collision
git clone -q "$UPSTREAM/foo" "$repo"
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" "$prefix") > /dev/null
echo original > "$repo/shared/replaced"
git -C "$repo" add shared/replaced
git -C "$repo" commit -qm 'File replaced by the incoming directory'
(
  cd "$OWNER/bar"
  mkdir replaced
  echo incoming > replaced/incoming
  git add replaced/incoming
  git commit -qm 'Incoming directory replacement'
  git push -q
)
printf '#!/bin/sh\necho hook-content > shared/replaced/local\nexit 1\n' > "$TMP/hooks/pre-commit"
printf '/shared/replaced/local\n' >> "$repo/.git/info/exclude"
git -C "$repo" config core.hooksPath "$TMP/hooks"
before=$(git -C "$repo" rev-parse HEAD)
run-operation pull shared --force
is "$status" 1 'rollback refuses to overwrite an ignored file created by the failing hook'
like "$(cat "$TMP/operation")" 'untracked or ignored.*overwritten' 'rollback reports the obstructing path'
is "$(cat "$repo/shared/replaced/local")" hook-content 'rollback preserves new hook content'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'refused rollback keeps the original HEAD'
is "$(git -C "$repo" write-tree)" "$(git config -f "$repo/.git/subrepo-integration" operation.tree)" \
  'refused rollback retains the prepared index for recovery'
git -C "$repo" config --unset core.hooksPath
run-operation pull shared --force
is "$status" 0 'recovery completes after rollback was blocked by non-conflicting hook content'
is "$(cat "$repo/shared/replaced/local")" hook-content 'completed recovery retains the ignored hook file'
is "$(cat "$repo/shared/replaced/incoming")" incoming 'completed recovery retains the prepared upstream file'
is "$(git -C "$repo" diff --name-only; git -C "$repo" diff --cached --name-only)" "" \
  'completed recovery leaves tracked files and index clean'

done_testing
teardown
