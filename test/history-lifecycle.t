#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar) > /dev/null

before=$(git -C "$repo" rev-parse HEAD)
mkdir "$TMP/hooks"
printf '#!/bin/sh\nexit 1\n' > "$TMP/hooks/pre-commit"
chmod +x "$TMP/hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hooks"
(
  cd "$OWNER/bar"
  echo incoming > incoming
  git add .
  git commit -qm 'Incoming for hook failure'
  git push -q
)
status=0
(cd "$repo" && git subrepo pull bar) > "$TMP/hook-error" 2>&1 || status=$?
is "$status" 1 'a real failing commit hook stops integration'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'hook failure preserves parent HEAD'
is "$(git -C "$repo" status --porcelain)" "" 'hook failure restores command-owned changes'
like "$(cat "$TMP/hook-error")" 'Project files were restored' 'hook error explains retained state'
git -C "$repo" config --unset core.hooksPath
(cd "$repo" && git subrepo pull bar) > /dev/null
is "$(cat "$repo/bar/incoming")" incoming 'retry after a hook failure completes the import'

(
  cd "$repo"
  echo published > bar/published
  git add .
  git commit -qm 'Local publication'
)
before=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" config core.hooksPath "$TMP/hooks"
status=0
(cd "$repo" && git subrepo push bar) > "$TMP/push-error" 2>&1 || status=$?
is "$status" 1 'failed local finalization is not reported as push success'
like "$(cat "$TMP/push-error")" 'were sent upstream, but the local record' \
  'partial-success message distinguishes remote publication from local state'
is "$(git --git-dir="$UPSTREAM/bar" show master:published)" published \
  'remote publication actually succeeded before the local failure'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'failed local publication record restores parent HEAD'
remote=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
git -C "$repo" config --unset core.hooksPath
(cd "$repo" && git subrepo push bar) > "$TMP/retry"
is "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" "$remote" \
  'retry does not create or push another upstream contribution'
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.commit)" "$remote" \
  'retry records the already-published original upstream tip'
like "$(cat "$TMP/retry")" 'already sent upstream' 'retry explains that it only completes the local record'

(
  cd "$OWNER/bar"
  git pull -q
  echo resumed > interrupted
  git add .
  git commit -qm 'Incoming for interruption'
  git push -q
)
cat > "$TMP/hooks/pre-commit" <<'EOF'
#!/bin/sh
kill -TERM "$GIT_SUBREPO_RUNNING"
exit 1
EOF
git -C "$repo" config core.hooksPath "$TMP/hooks"
before=$(git -C "$repo" rev-parse HEAD)
status=0
(cd "$repo" && git subrepo pull bar) > "$TMP/interrupted" 2>&1 || status=$?
is "$status" 143 'an actual interrupted Git operation exits without reporting success'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'interruption does not advance the parent prematurely'
test-exists "$repo/.git/subrepo-integration"
git -C "$repo" config --unset core.hooksPath
(cd "$repo" && git subrepo pull bar) > "$TMP/resumed"
is "$(cat "$repo/bar/interrupted")" resumed 'the exact retry completes the journaled import'
is "$(git -C "$repo" status --porcelain)" "" 'resumed import leaves no staged or working changes'
test-exists "!$repo/.git/subrepo-integration" "!$repo/.git/tmp/subrepo/bar/"

(
  cd "$OWNER/bar"
  echo survived > killed
  git add killed
  git commit -qm 'Incoming for abrupt termination'
  git push -q
)
cat > "$TMP/hooks/pre-commit" <<'EOF'
#!/bin/sh
kill -KILL "$GIT_SUBREPO_RUNNING"
exit 1
EOF
git -C "$repo" config core.hooksPath "$TMP/hooks"
status=0
(cd "$repo" && git subrepo pull bar) > "$TMP/killed" 2>&1 || status=$?
is "$status" 137 'SIGKILL leaves an interrupted operation rather than claiming success'
test-exists "$repo/.git/subrepo-operation.lock/"
interrupted_lease=$(git -C "$repo" rev-parse refs/subrepo-operation-lock)
interrupted_tmp=$(git -C "$repo" config --blob "$interrupted_lease" lock.nonce)
test-exists "$interrupted_tmp/"
git -C "$repo" config --unset core.hooksPath
for ((attempt = 0; attempt < 100; attempt++)); do
  [[ -e $repo/.git/index.lock ]] || break
  sleep 0.05
done
mkdir "$repo/.git/review-protected"
echo preserved > "$repo/.git/review-protected/keep"
git -C "$repo" cat-file blob "$interrupted_lease" > "$TMP/invalid-lease"
git config -f "$TMP/invalid-lease" lock.nonce "$interrupted_tmp/../review-protected"
invalid_lease=$(git -C "$repo" hash-object -w "$TMP/invalid-lease")
git -C "$repo" update-ref refs/subrepo-operation-lock "$invalid_lease" "$interrupted_lease"
status=0
(cd "$repo" && git subrepo pull bar) > "$TMP/invalid-nonce" 2>&1 || status=$?
is "$status" 1 'stale lease recovery refuses a temporary path outside its owned directory'
like "$(cat "$TMP/invalid-nonce")" 'invalid temporary-directory record' \
  'unsafe cleanup records produce explicit recovery guidance'
is "$(cat "$repo/.git/review-protected/keep")" preserved 'recovery does not delete unrelated files'
is "$(git -C "$repo" rev-parse refs/subrepo-operation-lock)" "$invalid_lease" \
  'invalid lease refusal preserves the recovery record for inspection'
git -C "$repo" update-ref refs/subrepo-operation-lock "$interrupted_lease" "$invalid_lease"
(cd "$repo" && git subrepo pull bar) > "$TMP/reclaimed"
like "$(cat "$TMP/reclaimed")" 'Recovered an interrupted operation lock' \
  'retry validates and reclaims the dead owner without manual lock deletion'
is "$(cat "$repo/bar/killed")" survived 'retry completes the journal left by abrupt termination'
is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo-operation-lock)" "" \
  'successful completion releases the atomic operation lease'
is "$(git -C "$repo" status --porcelain)" "" 'abrupt-termination recovery leaves a clean project'
test-exists "!$interrupted_tmp/"

echo transport > "$repo/bar/before-transport"
git -C "$repo" add bar/before-transport
git -C "$repo" commit -qm 'Prepared publication'
cat > "$TMP/hooks/pre-push" <<'EOF'
#!/bin/sh
kill -TERM "$GIT_SUBREPO_RUNNING"
exit 1
EOF
chmod +x "$TMP/hooks/pre-push"
rm "$TMP/hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hooks"
remote_before=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
status=0
(cd "$repo" && git subrepo push bar) > "$TMP/prepared" 2>&1 || status=$?
is "$status" 143 'a real pre-push interruption leaves the prepared publication resumable'
is "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" "$remote_before" \
  'pre-push interruption does not advance the remote'
prepared=$(git config -f "$repo/.git/subrepo-pending/bar/push" push.commit)
git -C "$repo" config --unset core.hooksPath
(cd "$repo" && git subrepo push bar) > "$TMP/transport-retry" 2>&1
is "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" "$prepared" \
  'retry publishes the exact prepared commit when transport never started'
is "$(git -C "$repo" status --porcelain)" "" 'prepared-publication retry leaves a clean parent'

git -C "$repo" config -f bar/.gitrepo subrepo-v2.rewriteFormat 99
git -C "$repo" add bar/.gitrepo
git -C "$repo" commit -qm 'Unsupported format fixture'
invalid=$(git -C "$repo" rev-parse HEAD)
status=0
(cd "$repo" && git subrepo pull bar --force) > "$TMP/format-error" 2>&1 || status=$?
is "$status" 1 'force does not bypass unsupported-format checks'
is "$(git -C "$repo" rev-parse HEAD)" "$invalid" 'unsupported format fails before modifying HEAD'
like "$(cat "$TMP/format-error")" 'Upgrade git-subrepo' 'unsupported format explains the upgrade requirement'
git -C "$repo" revert --no-edit HEAD > /dev/null

mkdir "$repo/.git/subrepo-operation.lock"
printf 'Another test operation in another worktree\n' > "$repo/.git/subrepo-operation.lock/owner"
status=0
(cd "$repo" && git subrepo fetch bar) > "$TMP/busy" 2>&1 || status=$?
is "$status" 1 'shared operation lock refuses a competing writer'
like "$(cat "$TMP/busy")" 'Finish that operation' 'busy message gives a safe next step'
rm "$repo/.git/subrepo-operation.lock/owner"
rmdir "$repo/.git/subrepo-operation.lock"
(cd "$repo" && git subrepo fetch bar) > /dev/null

git -C "$repo" mv bar moved
git -C "$repo" commit -qm 'Unsupported directory move'
status=0
(cd "$repo" && git subrepo pull moved) > "$TMP/moved" 2>&1 || status=$?
is "$status" 1 'moved prefixes are rejected before importing'
like "$(cat "$TMP/moved")" 'Move it back' 'move refusal explains how to return to supported use'

done_testing
teardown
