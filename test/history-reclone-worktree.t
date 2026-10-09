#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
echo stable > "$OWNER/bar/Stable"
git -C "$OWNER/bar" add Stable
git -C "$OWNER/bar" commit -qm 'Stable index entry'
git -C "$OWNER/bar" push -q

snapshot() {
  before=$(git -C "$repo" rev-parse HEAD)
  refs=$(git -C "$repo" show-ref)
  shared_before=$(git -C "$worktree" rev-parse HEAD)
  cp -R "$repo" "$TMP/project-before"
}

check-unchanged() {
  local label=$1
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$label preserves parent HEAD"
  is "$(git -C "$repo" show-ref)" "$refs" "$label preserves every ref"
  is "$(git -C "$worktree" rev-parse HEAD)" "$shared_before" "$label preserves extracted HEAD"
  # The operation lock writes a lease object even when an operation is refused.
  ok "$(diff -r --exclude=objects "$repo" "$TMP/project-before" > "$TMP/state-diff"; echo $?)" \
    "$label preserves exact files, indexes, metadata, reflogs and worktree registration"
  rm -rf "$TMP/project-before"
}

for command in clone pull; do
  for changes in unstaged staged untracked ignored conflict merge; do
    repo=$OWNER/$command-$changes
    remote=$UPSTREAM/$command-$changes
    git clone -q "$UPSTREAM/foo" "$repo"
    git clone -q --bare "$UPSTREAM/bar" "$remote"
    (
      cd "$repo"
      git subrepo clone "$remote" shared
      git subrepo branch shared
    ) > /dev/null
    worktree=$repo/.git/tmp/subrepo/shared
    git clone -q "$remote" "$OWNER/incoming-$command-$changes"
    (
      cd "$OWNER/incoming-$command-$changes"
      echo incoming > incoming
      git add incoming
      git commit -qm 'Replacement upstream'
      git push -q
    )
    case "$changes" in
      unstaged|staged)
        echo unfinished >> "$worktree/Bar"
        [[ $changes != staged ]] || git -C "$worktree" add Bar
        ;;
      untracked) echo unfinished > "$worktree/untracked" ;;
      ignored)
        echo ignored > "$repo/.git/info/exclude"
        echo unfinished > "$worktree/ignored"
        ;;
      conflict|merge)
        git -C "$worktree" checkout -qb side
        if [[ $changes == conflict ]]; then
          echo incoming > "$worktree/Bar"
        else
          echo incoming > "$worktree/side"
        fi
        git -C "$worktree" add .
        git -C "$worktree" commit -qm 'Side of unfinished merge'
        git -C "$worktree" checkout -q subrepo/shared
        echo manual > "$worktree/Bar"
        git -C "$worktree" add Bar
        git -C "$worktree" commit -qm 'Manual extracted commit'
        status=0
        git -C "$worktree" merge --no-commit --no-ff side > "$TMP/merge" 2>&1 || status=$?
        if [[ $changes == conflict ]]; then
          is "$status" 1 'fixture has a real unresolved merge'
          isnt "$(git -C "$worktree" ls-files -u)" "" 'fixture retains unmerged index stages'
        else
          # A merge can remain unfinished even with an index matching HEAD.
          git -C "$worktree" read-tree --reset -u HEAD
        fi
        ;;
    esac
    # Stale clean entries expose unintended status/update-index writes.
    touch -t 200001010000 "$repo/shared/Stable" "$worktree/Stable"
    snapshot
    args=(pull shared --force)
    [[ $command != clone ]] || args=(clone "$remote" shared --force)
    status=0
    (cd "$repo" && GIT_OPTIONAL_LOCKS=1 git subrepo "${args[@]}") > "$TMP/refused" 2>&1 || status=$?
    is "$status" 1 "$command refuses $changes extracted work before replacement"
    like "$(cat "$TMP/refused")" 'unfinished changes' "$command explains $changes refusal"
    check-unchanged "$command with $changes"
    is "$(git -C "$repo" ls-files shared/incoming)" "" "$command does not import replacement content"
  done
done

for command in clone pull; do
  repo=$OWNER/clean-$command
  git clone -q "$UPSTREAM/foo" "$repo"
  (
    cd "$repo"
    git subrepo clone "$UPSTREAM/bar" shared
    git subrepo branch shared
  ) > /dev/null
  worktree=$repo/.git/tmp/subrepo/shared
  echo manual > "$worktree/manual"
  git -C "$worktree" add manual
  git -C "$worktree" commit -qm 'Preserve committed extracted work'
  manual=$(git -C "$worktree" rev-parse HEAD)
  args=(pull shared --force)
  [[ $command != clone ]] || args=(clone "$UPSTREAM/bar" shared --force)
  snapshot
  (cd "$repo" && git subrepo "${args[@]}") > "$TMP/noop"
  check-unchanged "$command clean up-to-date worktree"
  # Same upstream tip, but committed parent content requires replacement.
  echo parent > "$repo/shared/parent"
  git -C "$repo" add shared/parent
  git -C "$repo" commit -qm 'Parent replacement fixture'
  before=$(git -C "$repo" rev-parse HEAD)
  (cd "$repo" && git subrepo "${args[@]}") > "$TMP/clean"
  is "$(git -C "$repo" rev-parse HEAD^1)" "$before" "$command clean replacement retains parent ancestry"
  is "$(git -C "$repo" ls-tree --name-only HEAD shared/parent)" "" "$command replaces committed parent edits"
  is "$(git -C "$repo" rev-parse subrepo/shared)" "$manual" "$command retains manual commits on the extracted branch"
  is "$(git -C "$repo" show subrepo/shared:manual)" manual "$command preserves committed extracted content"
  is "$(git -C "$repo" status --porcelain)" "" "$command clean replacement leaves a clean parent"
  test-exists "!$worktree/"
  before=$(git -C "$repo" rev-parse HEAD)
  (cd "$repo" && git subrepo "${args[@]}") > "$TMP/noop"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$command repeated replacement is a no-op"
done

repo=$OWNER/linked-owner
linked=$OWNER/linked
git clone -q "$UPSTREAM/foo" "$repo"
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" shared
  git subrepo branch shared
  git worktree add -qb linked "$linked"
) > /dev/null
worktree=$repo/.git/tmp/subrepo/shared
for command in clone pull; do
  touch -t 200001010000 "$linked/shared/Stable"
  snapshot
  cp -R "$linked" "$TMP/linked-before"
  args=(pull shared --force)
  [[ $command != clone ]] || args=(clone "$UPSTREAM/bar" shared --force)
  status=0
  (cd "$linked" && GIT_OPTIONAL_LOCKS=1 git subrepo "${args[@]}") > "$TMP/owner-message" 2>&1 || status=$?
  is "$status" 1 "$command cannot replace another linked owner's shared worktree"
  like "$(cat "$TMP/owner-message")" 'belongs to another project worktree' "$command explains ownership refusal"
  check-unchanged "$command with another owner"
  ok "$(diff -r "$linked" "$TMP/linked-before" > "$TMP/linked-diff"; echo $?)" \
    "$command ownership refusal preserves linked project files"
  rm -rf "$TMP/linked-before"
done

for command in clone pull; do
  repo=$OWNER/legacy-$command
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared --history=legacy) > /dev/null
  args=(pull shared --force)
  [[ $command != clone ]] || args=(clone "$UPSTREAM/bar" shared --force)
  before=$(git -C "$repo" rev-parse HEAD)
  (cd "$repo" && git subrepo "${args[@]}") > "$TMP/legacy-noop"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$command preserves legacy no-op behavior"
  echo "$command" > "$OWNER/bar/incoming"
  git -C "$OWNER/bar" add incoming
  git -C "$OWNER/bar" commit -qm 'Legacy replacement fixture'
  git -C "$OWNER/bar" push -q
  (cd "$repo" && git subrepo "${args[@]}") > "$TMP/legacy-clean"
  is "$(cat "$repo/shared/incoming")" "$command" "$command still replaces clean legacy content"
  is "$(git -C "$repo" config -f shared/.gitrepo subrepo.commit)" \
    "$(git -C "$OWNER/bar" rev-parse HEAD)" "$command retains legacy tracking format"
  is "$(git -C "$repo" status --porcelain)" "" "$command legacy replacement leaves a clean parent"
done

done_testing
teardown
