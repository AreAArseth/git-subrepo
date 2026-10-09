#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

for command in migrate retarget; do
  repo=$OWNER/preview-$command
  git clone -q "$UPSTREAM/foo" "$repo"
  history=legacy
  [[ $command != retarget ]] || history=prefixed
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared --history="$history") > /dev/null
  args=(migrate shared --history=prefixed --dry-run)
  [[ $command != retarget ]] || args=(retarget shared -b target --dry-run)

  for changes in clean unstaged staged; do
    for locked in false true; do
      git -C "$repo" reset --hard -q HEAD
      if [[ $changes != clean ]]; then
        echo 'Local change' >> "$repo/shared/Bar"
        [[ $changes != staged ]] || git -C "$repo" add shared/Bar
      fi
      # Make stat data stale deterministically without changing clean contents.
      touch -t 200001010000 "$repo/shared/Bar"
      cp "$repo/.git/index" "$TMP/index-before"
      if $locked; then
        printf 'Existing index lock\n' > "$repo/.git/index.lock"
        cp "$repo/.git/index.lock" "$TMP/lock-before"
      fi
      status=0
      (cd "$repo" && GIT_OPTIONAL_LOCKS=1 git subrepo "${args[@]}") > "$TMP/preview" 2>&1 || status=$?
      label="$command preview, $changes, locked=$locked"
      if [[ $changes == clean ]]; then
        is "$status" 0 "$label succeeds with stale index stat data"
        if [[ $command == migrate ]]; then
          like "$(cat "$TMP/preview")" 'Collaborators must use' "$label reports migration preview"
        else
          like "$(cat "$TMP/preview")" 'Preview only: the remote was checked' "$label reports retarget preview"
        fi
      else
        is "$status" 1 "$label refuses dirty work"
        reason='Unstaged changes'
        [[ $changes != staged ]] || reason='Index has changes'
        like "$(cat "$TMP/preview")" "Can't $command subrepo. $reason" "$label explains dirty work"
      fi
      ok "$(cmp -s "$repo/.git/index" "$TMP/index-before"; echo $?)" "$label preserves index bytes"
      if $locked; then
        ok "$(cmp -s "$repo/.git/index.lock" "$TMP/lock-before"; echo $?)" "$label preserves the existing lock"
        rm "$repo/.git/index.lock"
      else
        present=0
        [[ ! -e "$repo/.git/index.lock" ]] || present=1
        is "$present" 0 "$label leaves no index lock"
      fi
    done
  done
done

repo=$OWNER/preview-shared-worktree
remote=$UPSTREAM/preview-shared-worktree
echo 'Unchanged shared file' > "$OWNER/bar/Stable"
git -C "$OWNER/bar" add Stable
git -C "$OWNER/bar" commit -qm 'Add stable fixture file'
git clone -q "$UPSTREAM/foo" "$repo"
git clone -q --bare "$OWNER/bar" "$remote"
(
  cd "$repo"
  git subrepo clone "$remote" shared
  git subrepo branch shared
) > /dev/null
repo=$(cd "$repo" && pwd -P)
worktree=$repo/.git/tmp/subrepo/shared
shared_index=$(git -C "$worktree" rev-parse --git-path index)
[[ $shared_index == /* ]] || shared_index=$worktree/$shared_index

for command in retarget migrate; do
  args=("$command" shared --dry-run)
  [[ $command != retarget ]] || args+=(-b target)
  for changes in clean unstaged staged; do
    for locked in false true; do
      git -C "$worktree" reset --hard -q HEAD
      if [[ $changes != clean ]]; then
        echo 'Shared worktree change' >> "$worktree/Bar"
        [[ $changes != staged ]] || git -C "$worktree" add Bar
      fi
      # Include an unchanged stale entry even when Bar has staged/unstaged work.
      touch -t 200001010000 "$repo/shared/Stable" "$worktree/Stable" "$worktree/Bar"
      if $locked; then
        printf 'Existing parent index lock\n' > "$repo/.git/index.lock"
        printf 'Existing shared index lock\n' > "$shared_index.lock"
      fi
      cp -R "$repo" "$TMP/project-before"
      cp -R "$remote" "$TMP/remote-before"
      status=0
      (cd "$repo" && GIT_OPTIONAL_LOCKS=1 git subrepo "${args[@]}") > "$TMP/preview" 2>&1 || status=$?
      output=$(cat "$TMP/preview")
      label="$command preview, shared $changes, locked=$locked"
      if [[ $command == retarget ]]; then
        is "$status" 0 "$label succeeds"
        like "$output" 'Preview only: the remote was checked' "$label reports preview"
        worktree_status=$(sed -n '/Uncommitted work there/,/Worktree\/project file differences/{ /Uncommitted work there/d; /Worktree\/project file differences/d; p; }' "$TMP/preview")
      else
        is "$status" 1 "$label refuses an existing shared operation"
        like "$output" 'Finish the existing shared operation there before retrying' "$label explains refusal"
        worktree_status=$(sed -n '/Shared worktree:/,/Finish the existing shared operation/{ /Shared worktree:/d; /Finish the existing shared operation/d; p; }' "$TMP/preview")
      fi
      case "$changes" in
        clean)
          expected=''
          [[ $command != migrate ]] || expected='No uncommitted files; committed work may still need preserving.'
          ;;
        unstaged) expected=' M Bar' ;;
        staged) expected='M  Bar' ;;
      esac
      is "$worktree_status" "$expected" "$label reports exact shared cleanliness"
      ok "$(cmp -s "$repo/.git/index" "$TMP/project-before/.git/index"; echo $?)" \
        "$label preserves exact parent index bytes"
      ok "$(cmp -s "$shared_index" "$TMP/project-before/${shared_index#"$repo/"}"; echo $?)" \
        "$label preserves exact shared index bytes"
      ok "$(diff -r "$repo" "$TMP/project-before" > "$TMP/project-diff"; echo $?)" \
        "$label preserves all parent/shared files, objects, refs and locks"
      ok "$(diff -r "$remote" "$TMP/remote-before" > "$TMP/remote-diff"; echo $?)" \
        "$label preserves all destination files, objects and refs"
      rm -rf "$TMP/project-before" "$TMP/remote-before"
      if $locked; then
        rm "$repo/.git/index.lock" "$shared_index.lock"
      fi
    done
  done
done

done_testing
teardown
