#!/usr/bin/env bash

set -e

source test/setup

use Test::More

# 'subrepo:branch' walks '$subrepo_parent..HEAD' forward and keeps a commit
# only when it is a direct child of the last kept one. A commit with no
# '.gitrepo' file is skipped without advancing that ancestor, which severs the
# chain: every later commit, including HEAD, is then rejected as "not in the
# selected path". The reconstructed branch stops early, so it neither contains
# the current upstream nor matches the current subdir tree.
#
# See note/status-push-disagreement.md.
[[ ${GIT_SUBREPO_TEST_KNOWN_FAILURES-} ]] ||
  plan skip_all "Known failure, see note/status-push-disagreement.md"

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

note "$(cd "$OWNER/foo"; git log --graph --oneline)"

branch_output=$(
  cd "$OWNER/foo"
  git subrepo clean bar > /dev/null
  catch git subrepo -F branch bar
)

note "branch output: $branch_output"

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

push_output=$(
  cd "$OWNER/foo"
  git subrepo clean bar > /dev/null
  catch git subrepo push bar
)

note "push output: $push_output"

unlike "$push_output" \
  "doesn't contain upstream HEAD" \
  "push does not reject its own reconstructed branch"

done_testing 3

teardown
