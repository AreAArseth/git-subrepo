#!/usr/bin/env bash

source test/setup

use Test::More

clone-foo-and-bar

subrepo-clone-bar-into-foo

(
  cd "$OWNER/bar"
  git checkout -b branch1
  echo "branch1 change" > branch1.txt
  git add branch1.txt
  git commit -m "branch1 change"
  git push --set-upstream origin branch1
) &> /dev/null || die

(
  cd "$OWNER/foo"
  git subrepo retarget bar -b branch1 -u
) &> /dev/null || die

gitrepo=$OWNER/foo/bar/.gitrepo
test-gitrepo-field branch branch1

(
  cd "$OWNER/foo"
  git add bar/.gitrepo
  git commit -m "Update bar subrepo branch"
) &> /dev/null || die

(
  cd "$OWNER/foo"
  git subrepo pull bar
) &> /dev/null || die

done_testing

teardown
