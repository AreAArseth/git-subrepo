#!/usr/bin/env bash

set -e
source test/setup
use Test::More
export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true

for edits in 1 2; do
  remote=$UPSTREAM/shared-$edits
  author=$OWNER/author-$edits
  project=$OWNER/project-$edits
  fresh=$OWNER/fresh-$edits
  git clone -q --bare "$UPSTREAM/bar" "$remote"
  git clone -q "$remote" "$author"
  git clone -q "$UPSTREAM/foo" "$project"
  worktree=$project/.git/tmp/subrepo/bar
  (
    cd "$author"
    echo baseline > value
    echo baseline > unrelated
    git add .
    git commit -qm 'Shared baseline'
    git push -q
    cd "$project"
    git subrepo clone "$remote" bar --method=rebase
    for ((edit=1; edit<=edits; edit++)); do
      echo "local $edit" > bar/value
      git add .
      git -c user.name=Alice -c user.email=alice@example.invalid commit -qm "Local edit $edit"
    done
    cd "$author"
    echo incoming > value
    git add .
    git commit -qm 'Incoming edit'
    git push -q
  ) > "$TMP/setup.log" 2>&1

  before=$(git -C "$project" rev-parse HEAD)
  status=0
  git -C "$project" subrepo pull bar > "$TMP/conflict.log" 2>&1 || status=$?
  is "$status" 1 "$edits edits: initial incompatible change requires resolution"
  is "$(git -C "$project" rev-parse HEAD)" "$before" 'conflict keeps the parent HEAD'
  status=0
  git -C "$project" subrepo commit bar > "$TMP/unfinished.log" 2>&1 || status=$?
  is "$status" 1 'unfinished rebase cannot be recorded'
  is "$(git -C "$project" rev-parse HEAD)" "$before" 'unfinished rebase refusal keeps the parent HEAD'
  for ((edit=1; edit<=edits; edit++)); do
    is "$(git -C "$worktree" diff --name-only --diff-filter=U)" value \
      "local edit $edit conflicts in the expected shared file"
    echo "resolved $edit" > "$worktree/value"
    git -C "$worktree" add value
    status=0
    git -C "$worktree" rebase --continue > "$TMP/continue.log" 2>&1 || status=$?
    expected=0
    if (( edit < edits )); then expected=1; fi
    is "$status" "$expected" "resolution of local edit $edit advances the rebase"
  done
  replay=$(git -C "$worktree" rev-parse HEAD)

  if [[ $edits == 2 ]]; then
    printf '#!/bin/sh\nexit 1\n' > "$project/.git/hooks/pre-commit"
    chmod +x "$project/.git/hooks/pre-commit"
    status=0
    git -C "$project" subrepo commit bar > "$TMP/interrupted.log" 2>&1 || status=$?
    is "$status" 1 'a failing real commit hook interrupts the resolution record'
    is "$(git -C "$project" rev-parse HEAD)" "$before" 'failed record restores the parent HEAD'
    is "$(git -C "$project" status --porcelain)" "" 'failed record restores a clean parent tree'
    is "$(git -C "$worktree" rev-parse HEAD)" "$replay" 'failed record retains the completed replay'
    rm "$project/.git/hooks/pre-commit"
  fi
  git -C "$project" subrepo commit bar > "$TMP/resolution.log" 2>&1
  is "$(cat "$project/bar/value")" "resolved $edits" 'recorded rebase installs the chosen resolution'
  is "$(git -C "$project" rev-parse HEAD^1)" "$before" 'record keeps original local project ancestry'
  mapped=$(git -C "$project" config -f bar/.gitrepo subrepo-v2.mappedCommit)
  status=0
  git -C "$project" merge-base --is-ancestor "$mapped" HEAD || status=$?
  is "$status" 0 'record retains the mapped upstream ancestry'
  before=$(git -C "$project" rev-parse HEAD)
  git -C "$project" subrepo pull bar > "$TMP/noop.log" 2>&1
  is "$(git -C "$project" rev-parse HEAD)" "$before" 'pull before upstream advances is a no-op'
  git clone -q --no-local --single-branch --branch master "$project" "$fresh"
  is "$(git -C "$fresh" for-each-ref --format='%(refname)' refs/subrepo refs/heads/subrepo)" "" \
    'fresh clone has no special refs, mapping cache, or shared branch'
  status=0
  git -C "$fresh" cat-file -e "$replay^{commit}" 2>/dev/null || status=$?
  isnt "$status" 0 'fresh clone cannot rely on the original unpublished replay objects'

  for cycle in 1 2; do
    (
      cd "$author"
      echo "unrelated incoming $cycle" > unrelated
      git add .
      git commit -qm "Unrelated incoming edit $cycle"
      git push -q
    ) > "$TMP/upstream.log" 2>&1
    for repo in "$project" "$fresh"; do
      if [[ $cycle == 2 ]]; then
        (
          cd "$repo"
          echo 'later local work' > bar/later
          echo 'parent-only work' > parent-only
          git add .
          git -c user.name=Bob -c user.email=bob@example.invalid commit -qm 'Later local and parent work'
        )
      fi
      status=0
      git -C "$repo" subrepo pull bar > "$TMP/followup.log" 2>&1 || status=$?
      is "$status" 0 "$edits edits, cycle $cycle, ${repo##*/}: unrelated pull does not reopen the conflict"
      is "$(cat "$repo/bar/value")" "resolved $edits" 'later pull preserves the exact chosen resolution'
      is "$(cat "$repo/bar/unrelated")" "unrelated incoming $cycle" 'later pull imports the independent change'
      if [[ $cycle == 2 ]]; then
        is "$(cat "$repo/bar/later")" 'later local work' 'later local shared work survives the replay'
        is "$(cat "$repo/parent-only")" 'parent-only work' 'parent-only work stays intact'
      fi
    done
  done

  # A separate upstream fork introduces a genuinely incompatible change while
  # the chosen resolution is still unpublished on either remote.
  conflicting=$UPSTREAM/conflicting-$edits
  conflict_author=$OWNER/conflicting-author-$edits
  git clone -q --bare "$remote" "$conflicting"
  git clone -q "$conflicting" "$conflict_author"
  (
    cd "$conflict_author"
    echo incompatible > value
    git add .
    git commit -qm 'New incompatible edit'
    git push -q
  )
  before=$(git -C "$project" rev-parse HEAD)
  status=0
  git -C "$project" subrepo pull bar --remote="$conflicting" > "$TMP/new-conflict.log" 2>&1 || status=$?
  is "$status" 1 'genuinely incompatible incoming edit still conflicts'
  is "$(git -C "$project" rev-parse HEAD)" "$before" 'new conflict preserves the parent HEAD'
  is "$(git -C "$worktree" show :2:value)" incompatible 'new conflict shows the actual incoming value'
  is "$(git -C "$worktree" show :3:value)" 'resolved 1' \
    'new conflict replays the chosen resolution rather than a superseded local edit'
  is "$(git -C "$worktree" show :1:value)" incoming 'new conflict uses the post-resolution upstream base'

  observer=$OWNER/observer-$edits
  git clone -q "$UPSTREAM/foo" "$observer"
  git -C "$observer" subrepo clone "$remote" bar > "$TMP/observer.log" 2>&1
  upstream_before=$(git --git-dir="$remote" rev-parse master)
  git -C "$fresh" subrepo push bar > "$TMP/push.log" 2>&1
  is "$(git --git-dir="$remote" show master:value)" "resolved $edits" 'eventual push publishes the exact resolution'
  is "$(git --git-dir="$remote" show master:later)" 'later local work' 'eventual push publishes later local work'
  is "$(git --git-dir="$remote" log --format=%s "$upstream_before..master" -- value)" \
    "$(for ((edit=edits; edit>=1; edit--)); do echo "Local edit $edit"; done)" \
    'publication retains each resolved local commit instead of squashing them'
  is "$(git --git-dir="$remote" log --format='%an <%ae>' "$upstream_before..master" -- value | sort -u)" \
    'Alice <alice@example.invalid>' 'resolved local commits retain original authorship'
  is "$(git --git-dir="$remote" log -1 --format=%an -- later)" Bob 'later work retains its distinct author'
  is "$(git --git-dir="$remote" log --format= --name-only master |
    grep -E '(^|/)\.gitrepo$|^bar/|^Foo$|^parent-only$' || true)" "" \
    'published history contains no tracking, prefixed, or project-only paths'
  is "$(git --git-dir="$remote" rev-list "$upstream_before..master" |
    git --git-dir="$remote" cat-file --batch | grep '^git-subrepo-rewrite ' || true)" "" \
    'published history contains no browsing-only rewrite headers'
  git -C "$observer" subrepo pull bar > "$TMP/observer-pull.log" 2>&1
  is "$(cat "$observer/bar/value")" "resolved $edits" 'another project imports the published resolution'
  is "$(cat "$observer/bar/later")" 'later local work' 'another project imports the later work'
  before=$(git -C "$fresh" rev-parse HEAD)
  upstream_before=$(git --git-dir="$remote" rev-parse master)
  for retry in 1 2; do
    git -C "$fresh" subrepo pull bar > "$TMP/noop-pull-$retry.log" 2>&1
    git -C "$fresh" subrepo push bar > "$TMP/noop-push-$retry.log" 2>&1
  done
  is "$(git -C "$fresh" rev-parse HEAD)" "$before" 'repeated up-to-date operations create no project commits'
  is "$(git --git-dir="$remote" rev-parse master)" "$upstream_before" 'repeated pushes create no upstream commits'
  is "$(git -C "$fresh" status --porcelain)" "" 'completed replay and publication leave a clean project'
done

done_testing
teardown
