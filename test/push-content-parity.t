#!/usr/bin/env bash

set -e

source test/setup

use Test::More

# 'push' used to reconstruct the whole '$subrepo_parent..HEAD' range before it
# could conclude there was nothing to send, and its no-op exit recorded nothing,
# so every later invocation redid the same work and 'status' kept reporting the
# same stale range. Matching subdir content now short-circuits the
# reconstruction and records the sync point instead.
#
# See note/status-push-disagreement.md.

clone-foo-and-bar
subrepo-clone-bar-into-foo

# Push once so local and upstream agree, then add local subdir history whose net
# content change is zero. The subdir content matches upstream, but the recorded
# parent is behind and commits touching the subdir sit in between.
(
  cd "$OWNER/foo"
  add-new-files bar/local1
  git subrepo push bar
  add-new-files bar/temp.txt
  remove-files bar/temp.txt
) >& /dev/null || die

head_before=$(cd "$OWNER/foo"; git rev-parse HEAD)
count_before=$(cd "$OWNER/foo"; git rev-list --count HEAD)

is "$(
  cd "$OWNER/foo"
  catch git subrepo push bar
)" \
  "Subrepo 'bar' has no new commits to push.
Recorded the sync point in 'bar/.gitrepo'." \
  "push reports no new commits and records the sync point"

# shellcheck disable=2034
gitrepo=$OWNER/foo/bar/.gitrepo
test-gitrepo-field "parent" "$head_before"

is "$(cd "$OWNER/foo"; git rev-list --count HEAD)" \
  "$(( count_before + 1 ))" \
  "recording the sync point adds exactly one commit"

is "$(cd "$OWNER/foo"; git log -1 --format=%s)" \
  "git subrepo push (sync) bar" \
  "the sync commit is marked as a sync"

is "$(
  cd "$OWNER/foo"
  git subrepo status bar | grep 'Push:'
)" \
  "  Push:           up to date" \
  "status agrees that there is nothing to push"

# With the sync point recorded there is nothing left for a second push to do.
head_after=$(cd "$OWNER/foo"; git rev-parse HEAD)

is "$(
  cd "$OWNER/foo"
  catch git subrepo push bar
)" \
  "Subrepo 'bar' has no new commits to push." \
  "a second push is a plain no-op"

is "$(cd "$OWNER/foo"; git rev-parse HEAD)" \
  "$head_after" \
  "a plain no-op push adds no commit"

# A real content change must still take the normal path.
(
  cd "$OWNER/foo"
  add-new-files bar/real-change.txt
) >& /dev/null || die

is "$(
  cd "$OWNER/foo"
  catch git subrepo push bar
)" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  "a real content change still pushes"

# History whose net content change is zero can still be sent upstream on
# purpose, by reconstructing it and pushing that branch explicitly.
(
  cd "$OWNER/foo"
  add-new-files bar/temp2.txt
  remove-files bar/temp2.txt
  git subrepo -F branch bar
) >& /dev/null || die

is "$(
  cd "$OWNER/foo"
  catch git subrepo push bar subrepo/bar
)" \
  "Subrepo 'bar' pushed to '$UPSTREAM/bar' (master)." \
  "net-zero history still pushes with an explicit branch"

(
  cd "$OWNER/bar"
  git pull
) >& /dev/null || die

test-exists \
  "$OWNER/bar/local1" \
  "$OWNER/bar/real-change.txt" \
  "!$OWNER/bar/temp.txt" \
  "!$OWNER/bar/temp2.txt" \
  "!$OWNER/bar/.gitrepo" \

is "$(
  cd "$OWNER/bar"
  git log --format=%s -- temp2.txt | tr '\n' ' '
)" \
  "Removed file: bar/temp2.txt add new file: bar/temp2.txt " \
  "the explicit branch carried the net-zero commits upstream"

done_testing 15

teardown
