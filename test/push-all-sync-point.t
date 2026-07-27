#!/usr/bin/env bash

set -e

source test/setup

use Test::More

# The '(sync)' marker in a commit subject comes from a flag that push sets when
# it records a content-parity sync point. That flag is per subrepo, so a '--all'
# run must not carry it from one subdir into the next and label a real upstream
# push as a sync.

clone-foo-and-bar

# A second upstream, so the two subrepos push to separate places.
cp -r "$UPSTREAM/bar" "$UPSTREAM/zzz"

(
  cd "$OWNER/foo"
  git subrepo clone "$UPSTREAM/bar" aaa
  git subrepo clone "$UPSTREAM/zzz" zzz

  # 'aaa' ends at content parity with pending history, so it takes the sync
  # path. Subrepos are processed in sorted order, so it runs before 'zzz'.
  add-new-files aaa/local1
  git subrepo push aaa
  add-new-files aaa/temp.txt
  remove-files aaa/temp.txt

  # 'zzz' has a real content change, so it must take the normal push path.
  add-new-files zzz/real.txt
) >& /dev/null || die

push_output=$(
  cd "$OWNER/foo"
  catch git subrepo push --all
)

like "$push_output" "Recorded the sync point in 'aaa/\.gitrepo'\." \
  "push --all records a sync point for the subrepo at content parity"

like "$push_output" "Subrepo 'zzz' pushed to" \
  "push --all really pushes the subrepo that has content"

subjects=$(cd "$OWNER/foo"; git log --format=%s -4)

like "$subjects" "git subrepo push zzz" \
  "the real push is committed without a marker"

unlike "$subjects" "git subrepo push \(sync\) zzz" \
  "the sync marker does not leak into the later real push"

like "$subjects" "git subrepo push \(sync\) aaa" \
  "the recorded sync point is still marked"

done_testing 5

teardown
