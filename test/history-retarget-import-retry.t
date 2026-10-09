#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

# Stop after the real import and worktree cleanup, before publication starts.
cat > "$TMP/stop-before-push" <<'EOF'
#!/usr/bin/env bash
source "$GIT_SUBREPO_ROOT/lib/git-subrepo"
history:push() {
  kill -KILL "$$"
}
main "$@"
EOF

for destination in existing missing; do
  repo=$OWNER/$destination
  remote=$UPSTREAM/$destination
  git clone -q "$UPSTREAM/foo" "$repo"
  git clone -q --bare "$UPSTREAM/bar" "$remote"
  if [[ $destination == existing ]]; then
    git --git-dir="$remote" update-ref refs/heads/target refs/heads/master
  fi
  (
    cd "$repo"
    git subrepo clone "$remote" shared
    echo local > shared/local
    git add shared/local
    git commit -qm 'Local shared contribution'
    git subrepo branch shared
  ) > /dev/null
  worktree=$repo/.git/tmp/subrepo/shared
  echo resolved > "$worktree/manual"
  git -C "$worktree" add manual
  git -C "$worktree" commit -qm 'Manually resolved shared contribution'
  before=$(git -C "$repo" rev-parse HEAD)
  remote_before=$(git --git-dir="$remote" show-ref)
  status=0
  (cd "$repo" && bash "$TMP/stop-before-push" retarget shared -b target) \
    > "$TMP/$destination-stop" 2>&1 || status=$?
  is "$status" 137 "$destination: SIGKILL stops exactly before push"
  imported=$(git -C "$repo" rev-parse HEAD)
  is "$(git -C "$repo" rev-list --first-parent --count "$before..HEAD")" 1 \
    "$destination: the import completed exactly once before interruption"
  is "$(git --git-dir="$remote" show-ref)" "$remote_before" \
    "$destination: interruption precedes publication"
  is "$(cat "$repo/shared/manual")" resolved "$destination: import retains manual work"
  test-exists "!$worktree/" "!$repo/.git/subrepo-pending/shared/push"

  (cd "$repo" && git subrepo retarget shared -b target) > "$TMP/$destination-retry" 2>&1
  is "$(git -C "$repo" rev-list --first-parent --count "$imported..HEAD")" 1 \
    "$destination: retry adds only the publication record, never another import"
  is "$(git -C "$repo" rev-parse HEAD^1)" "$imported" \
    "$destination: publication directly follows the completed import"
  is "$(git --git-dir="$remote" show target:local)" local \
    "$destination: retry publishes local content"
  is "$(git --git-dir="$remote" show target:manual)" resolved \
    "$destination: retry publishes the manual resolution"
  is "$(git -C "$repo" config -f shared/.gitrepo subrepo-v2.commit)" \
    "$(git --git-dir="$remote" rev-parse target)" "$destination: metadata records publication"
  is "$(git -C "$repo" status --porcelain)" "" "$destination: retry leaves the parent clean"
  test-exists "!$repo/.git/subrepo-integration" "!$repo/.git/subrepo-pending/shared/push"
  after=$(git -C "$repo" rev-parse HEAD)
  remote_after=$(git --git-dir="$remote" show-ref)
  (cd "$repo" && git subrepo retarget shared -b target) > "$TMP/$destination-noop" 2>&1
  is "$(git -C "$repo" rev-parse HEAD)" "$after" "$destination: subsequent retry is a parent no-op"
  is "$(git --git-dir="$remote" show-ref)" "$remote_after" "$destination: subsequent retry is a remote no-op"
  like "$(cat "$TMP/$destination-noop")" 'no changes made' "$destination: no-op is reported"
done

# Also exercise the earlier boundary, while the imported worktree still exists.
cat > "$TMP/stop-before-cleanup" <<'EOF'
#!/usr/bin/env bash
source "$GIT_SUBREPO_ROOT/lib/git-subrepo"
set -T
trap 'if [[ $BASH_COMMAND == history:remove-worktree &&
            -f $(git rev-parse --git-path subrepo-integration) ]]; then
  kill -KILL "$$"
fi' DEBUG
main "$@"
EOF

for change in incoming parent worktree dirty request prepared published noop; do
  repo=$OWNER/retry-$change
  remote=$UPSTREAM/retry-$change
  git clone -q "$UPSTREAM/foo" "$repo"
  git clone -q --bare "$UPSTREAM/bar" "$remote"
  git --git-dir="$remote" update-ref refs/heads/target refs/heads/master
  (cd "$repo" && git subrepo clone "$remote" shared) > /dev/null
  if [[ $change != noop ]]; then
    echo local > "$repo/shared/local"
    git -C "$repo" add shared/local
    git -C "$repo" commit -qm 'Local content to publish'
  fi
  runner=$TMP/stop-before-push
  if [[ $change == worktree || $change == dirty ]]; then
    runner=$TMP/stop-before-cleanup
  fi
  status=0
  (cd "$repo" && bash "$runner" retarget shared -b target) > "$TMP/stop-$change" 2>&1 || status=$?
  is "$status" 137 "$change: interrupted after a successful import"
  imported=$(git -C "$repo" rev-parse HEAD)
  remote_before=$(git --git-dir="$remote" show-ref)
  journal=$repo/.git/subrepo-integration
  is "$(git config -f "$journal" operation.phase)" retarget-import \
    "$change: successful import remains durably resumable"
  saved_journal=$(cat "$journal")
  worktree=$repo/.git/tmp/subrepo/shared
  retry_branch=target
  case $change in
    incoming)
      git clone -q -b target "$remote" "$OWNER/new-incoming"
      echo incoming > "$OWNER/new-incoming/incoming"
      git -C "$OWNER/new-incoming" add incoming
      git -C "$OWNER/new-incoming" commit -qm 'Incoming after interrupted import'
      git -C "$OWNER/new-incoming" push -q
      ;;
    parent)
      echo later > "$repo/shared/later"
      git -C "$repo" add shared/later
      git -C "$repo" commit -qm 'Parent changed after import'
      ;;
    worktree|dirty)
      echo later > "$worktree/later"
      if [[ $change == worktree ]]; then
        git -C "$worktree" add later
        git -C "$worktree" commit -qm 'Worktree changed after import'
      fi
      worktree_head=$(git -C "$worktree" rev-parse HEAD)
      ;;
    request)
      retry_branch=other
      ;;
    prepared|published)
      mkdir "$TMP/hooks-$change"
      if [[ $change == prepared ]]; then
        cat > "$TMP/hooks-$change/pre-push" <<'EOF'
#!/bin/sh
kill -TERM "$GIT_SUBREPO_RUNNING"
exit 1
EOF
      else
        printf '#!/bin/sh\nexit 1\n' > "$TMP/hooks-$change/pre-commit"
      fi
      chmod +x "$TMP/hooks-$change/"*
      git -C "$repo" config core.hooksPath "$TMP/hooks-$change"
      status=0
      (cd "$repo" && git subrepo retarget shared -b target) > "$TMP/pending-$change" 2>&1 || status=$?
      if [[ $change == prepared ]]; then
        is "$status" 143 'retarget stops with a prepared push before transport'
        is "$(git --git-dir="$remote" show-ref)" "$remote_before" 'prepared push has not changed the destination'
        is "$(git config -f "$journal" operation.phase)" retarget-import \
          'prepared push coexists with the durable import journal'
      else
        is "$status" 1 'retarget stops after transport when local recording fails'
        is "$(git config -f "$journal" operation.phase)" complete \
          'publication atomically replaces the import journal with finalization'
      fi
      candidate=$(git config -f "$repo/.git/subrepo-pending/shared/push" push.commit)
      if [[ $change == published ]]; then
        is "$(git --git-dir="$remote" rev-parse target)" "$candidate" \
          'the failed local record follows a real remote publication'
      fi
      git -C "$repo" config --unset core.hooksPath
      if [[ $change == prepared ]]; then
        git clone -q -b target "$remote" "$OWNER/pending-race"
        echo race > "$OWNER/pending-race/race"
        git -C "$OWNER/pending-race" add race
        git -C "$OWNER/pending-race" commit -qm 'Destination changed during pending publication'
        git -C "$OWNER/pending-race" push -q
        raced=$(git --git-dir="$remote" rev-parse target)
        status=0
        (cd "$repo" && git subrepo retarget shared -b target) > "$TMP/pending-race" 2>&1 || status=$?
        is "$status" 1 'changed destination with a pending push is refused'
        is "$(git --git-dir="$remote" rev-parse target)" "$raced" 'pending retry preserves changed destination'
        is "$(git -C "$repo" rev-parse HEAD)" "$imported" 'pending retry does not repeat the import'
        is "$(cat "$journal")" "$saved_journal" 'pending retry preserves import evidence'
        is "$(git config -f "$repo/.git/subrepo-pending/shared/push" push.commit)" "$candidate" \
          'pending retry preserves the exact prepared candidate'
        # Restore the destination for completion, retaining its new commit.
        git --git-dir="$remote" update-ref refs/heads/preserved-race "$raced"
        git --git-dir="$remote" update-ref refs/heads/target refs/heads/master
      fi
      ;;
  esac
  before_retry=$(git -C "$repo" rev-parse HEAD)
  status=0
  (cd "$repo" && git subrepo retarget shared -b "$retry_branch") > "$TMP/retry-$change" 2>&1 || status=$?
  case $change in
    parent|worktree|dirty|request)
      is "$status" 1 "$change: changed saved state is refused, not silently skipped"
      is "$(git -C "$repo" rev-parse HEAD)" "$before_retry" "$change: refusal preserves parent HEAD"
      is "$(git --git-dir="$remote" show-ref)" "$remote_before" "$change: refusal never publishes"
      is "$(cat "$journal")" "$saved_journal" "$change: refusal retains exact recovery evidence"
      if [[ $change == parent ]]; then
        is "$(cat "$repo/shared/later")" later 'new committed parent content survives'
      elif [[ $change == worktree || $change == dirty ]]; then
        is "$(cat "$worktree/later")" later "$change: new worktree content survives"
        is "$(git -C "$worktree" rev-parse HEAD)" "$worktree_head" "$change: worktree commits survive"
      fi
      ;;
    *)
      is "$status" 0 "$change: retry completes"
      count=1
      [[ $change != incoming ]] || count=2
      [[ $change != noop ]] || count=0
      is "$(git -C "$repo" rev-list --first-parent --count "$imported..HEAD")" "$count" \
        "$change: retry records only genuinely outstanding integrations"
      if [[ $change == incoming ]]; then
        is "$(git --git-dir="$remote" show target:incoming)" incoming 'changed destination content is integrated and published'
        is "$(cat "$repo/shared/incoming")" incoming 'changed destination content reaches the parent'
      elif [[ $change == prepared || $change == published ]]; then
        is "$(git --git-dir="$remote" rev-parse target)" "$candidate" 'retry completes the exact pending publication'
      elif [[ $change == noop ]]; then
        is "$(git --git-dir="$remote" show-ref)" "$remote_before" 'no-op publication leaves destination untouched'
      fi
      if [[ $change != noop ]]; then
        is "$(git --git-dir="$remote" show target:local)" local "$change: local content is published"
      fi
      is "$(git -C "$repo" status --porcelain)" "" "$change: successful retry leaves a clean parent"
      test-exists "!$journal" "!$repo/.git/subrepo-pending/shared/push"
      ;;
  esac
done

cat > "$TMP/stop-before-record" <<'EOF'
#!/usr/bin/env bash
source "$GIT_SUBREPO_ROOT/lib/git-subrepo"
history:integrate() {
  kill -KILL "$$"
}
main "$@"
EOF
repo=$OWNER/missing-published
remote=$UPSTREAM/missing-published
git clone -q "$UPSTREAM/foo" "$repo"
git clone -q --bare "$UPSTREAM/bar" "$remote"
(cd "$repo" && git subrepo clone "$remote" shared) > /dev/null
echo local > "$repo/shared/local"
git -C "$repo" add shared/local
git -C "$repo" commit -qm 'Publish to a missing destination without an import'
before=$(git -C "$repo" rev-parse HEAD)
status=0
(cd "$repo" && bash "$TMP/stop-before-record" retarget shared -b target) > "$TMP/missing-published" 2>&1 || status=$?
is "$status" 137 'missing destination: interruption after transport before finalization'
test-exists "!$repo/.git/subrepo-integration"
candidate=$(git config -f "$repo/.git/subrepo-pending/shared/push" push.commit)
is "$(git --git-dir="$remote" rev-parse target)" "$candidate" 'missing destination was actually created'
(cd "$repo" && git subrepo retarget shared -b target) > "$TMP/missing-published-retry" 2>&1
is "$(git -C "$repo" rev-parse HEAD^1)" "$before" 'pending-only retry adds one publication record, no import'
is "$(git --git-dir="$remote" rev-parse target)" "$candidate" 'pending-only retry does not republish'
is "$(git --git-dir="$remote" show target:local)" local 'pending-only retry preserves published local data'
is "$(git -C "$repo" config -f shared/.gitrepo subrepo-v2.commit)" "$candidate" \
  'pending-only retry records the actual publication'
test-exists "!$repo/.git/subrepo-integration" "!$repo/.git/subrepo-pending/shared/push"

done_testing
teardown
