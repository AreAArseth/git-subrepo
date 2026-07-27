#!/usr/bin/env bash

set -e

source test/setup

use Test::More

# 'subrepo:branch' walks '$subrepo_parent..HEAD' forward and keeps a commit
# only when it is a direct child of the last kept one. A commit with no
# readable '.gitrepo' is not recreated, but it still has to advance that
# ancestor, or every later commit is a child of a commit that was left out and
# the whole path is rejected as "not in the selected path". The reconstructed
# branch then stops early, so it neither contains the current upstream nor
# matches the current subdir tree.
#
# See note/status-push-disagreement.md.

clone-foo-and-bar

subrepo-clone-bar-into-foo

# Build a parent history where the recorded pull parent stays old, the subdir
# history forks and remerges after it, the subdir is briefly removed and
# restored, and only the mainline records the current upstream.
(
  cd "$OWNER/foo"
  clone_commit=$(git rev-parse HEAD)

  add-new-files bar/m1
  add-new-files bar/m2

  git checkout -b side "$clone_commit"
  add-new-files bar/s1
  add-new-files bar/s2

  git checkout master
  git merge --no-edit side

  # This puts a commit with no '.gitrepo' file into the range.
  git rm -r bar
  git commit -m "remove subrepo dir"
  git revert --no-edit HEAD

  (
    cd "$OWNER/bar"
    add-new-files upstream-new.txt
    git push origin master
  )
  git subrepo pull bar

  add-new-files bar/m3
) >& /dev/null || die

branch_output=$(
  cd "$OWNER/foo"
  git subrepo clean bar > /dev/null
  catch git subrepo -F branch bar
)

is "$branch_output" \
  "Created branch 'subrepo/bar' and worktree '.git/tmp/subrepo/bar'." \
  "subrepo branch command output is correct"

contains_upstream=0
(
  cd "$OWNER/foo"
  git merge-base --is-ancestor refs/subrepo/bar/fetch refs/subrepo/bar/branch
) || contains_upstream=$?

ok "$contains_upstream" \
  "reconstructed branch contains the upstream HEAD"

is "$(
  cd "$OWNER/foo"
  git diff --name-status \
    refs/subrepo/bar/branch HEAD:bar -- . ':(exclude).gitrepo'
)" \
  "" \
  "reconstructed branch tree matches the subdir, ignoring .gitrepo"

is "$(
  cd "$OWNER/foo"
  git subrepo clean bar > /dev/null
  catch git subrepo push bar
)" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  "push accepts its own reconstructed branch"

(
  cd "$OWNER/bar"
  git pull
) >& /dev/null || die

test-exists \
  "$OWNER/bar/m1" \
  "$OWNER/bar/m2" \
  "$OWNER/bar/m3" \
  "$OWNER/bar/s1" \
  "$OWNER/bar/s2" \
  "!$OWNER/bar/.gitrepo" \

# A real local change must still reach upstream from the same history.
(
  cd "$OWNER/foo"
  add-new-files bar/real-change.txt
) >& /dev/null || die

is "$(
  cd "$OWNER/foo"
  catch git subrepo push bar
)" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  "a real local change still pushes"

(
  cd "$OWNER/bar"
  git pull
) >& /dev/null || die

test-exists "$OWNER/bar/real-change.txt"

# And with --squash, which reconstructs a single snapshot instead.
(
  cd "$OWNER/foo"
  add-new-files bar/squashed-change.txt
) >& /dev/null || die

is "$(
  cd "$OWNER/foo"
  catch git subrepo push bar --squash
)" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  "a real local change still pushes with --squash"

(
  cd "$OWNER/bar"
  git pull
) >& /dev/null || die

test-exists "$OWNER/bar/squashed-change.txt"

done_testing 14

teardown
