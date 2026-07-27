#!/usr/bin/env bash

set -e

source test/setup

use Test::More

clone-foo-and-bar

(
  cd "$OWNER"/foo
  git subrepo clone "$UPSTREAM"/bar
  git subrepo clone "$UPSTREAM"/foo bar/foo
  mkdir lib
  git subrepo clone "$UPSTREAM"/bar lib/bar
  git subrepo clone "$UPSTREAM"/foo lib/bar/foo
) &> /dev/null || die

{
  output=$(
    cd "$OWNER"/foo
    git subrepo status --all
  )

  like "$output" "2 subrepos:" \
    "'status' intro ok"

  like "$output" "Git subrepo 'bar':" \
    "bar is in 'status'"

  like "$output" "Git subrepo 'lib/bar':" \
    "lib/bar is in 'status'"

  unlike "$output" "Git subrepo 'bar/foo':" \
    "bar/foo is not in 'status'"

  unlike "$output" "Git subrepo 'lib/bar/foo':" \
    "lib/bar/foo is not in 'status'"
}

{
  output=$(
    cd "$OWNER"/foo
    git subrepo status --ALL
  )

  like "$output" "4 subrepos:" \
    "'status --ALL' intro ok"

  like "$output" "Git subrepo 'bar':" \
    "bar is in 'status --ALL'"

  like "$output" "Git subrepo 'lib/bar':" \
    "lib/bar is in 'status --ALL'"

  like "$output" "Git subrepo 'bar/foo':" \
    "bar/foo is in 'status --ALL'"

  like "$output" "Git subrepo 'lib/bar/foo':" \
    "lib/bar/foo is in 'status --ALL'"
}

{
  output=$(
    cd "$OWNER"/foo
    git subrepo status --all
  )

  like "$output" "2 subrepos:" \
    "'status --all' intro ok"

  like "$output" "Git subrepo 'bar':" \
    "bar is in 'status --all'"

  like "$output" "Git subrepo 'lib/bar':" \
    "lib/bar is in 'status --all'"

  unlike "$output" "Git subrepo 'bar/foo':" \
    "bar/foo is not in 'status --all'"

  unlike "$output" "Git subrepo 'lib/bar/foo':" \
    "lib/bar/foo is not in 'status --all'"
}

{
  (
    cd "$OWNER/bar"
    branch=$(git symbolic-ref --short HEAD)
    echo "remote update" >> remote-change.txt
    git add remote-change.txt
    git commit --quiet -m "remote change for status"
    git push --quiet origin "$branch"
  )

  output=$(
    cd "$OWNER"/foo
    git subrepo status bar --fetch
  )

  like "$output" "Pull: *1 commit" \
    "status shows remote commits to pull"

  like "$output" "Push: *1 commit" \
    "status shows existing local commits"

  output=$(
    cd "$OWNER"/foo
    git subrepo status bar --fetch --log
  )

  like "$output" "Remote commits:" \
    "log flag prints remote commit header"

  like "$output" "remote change for status" \
    "log flag prints remote commit subject"

  output=$(
    cd "$OWNER"/foo
    git subrepo status bar --fetch --diff
  )

  like "$output" "Remote diff:" \
    "diff flag prints remote diff header"
}

{
  (
    cd "$OWNER"/foo
    echo "local change" >> bar/local-change.txt
    git add bar/local-change.txt
    git commit --quiet -m "local change for status"
  )

  output=$(
    cd "$OWNER"/foo
    git subrepo status bar --log --diff
  )

  like "$output" "Push: *2 commits" \
    "status shows local commits to push"

  like "$output" "Local commits:" \
    "log flag prints local commit header"

  like "$output" "local change for status" \
    "log flag prints local commit subject"

  like "$output" "Local diff:" \
    "diff flag prints local diff header"
}

# 'bar' has a nested subrepo, so use a clean parent repo to compare a subrepo
# whose content is identical to its upstream.
{
  (
    cd "$OWNER/bar"
    git subrepo clone "$UPSTREAM/foo"
    add-new-files foo/tmpfile
    remove-files foo/tmpfile
  ) &> /dev/null || die

  output=$(
    cd "$OWNER/bar"
    git subrepo status foo --log --diff
  )

  like "$output" "Push: *up to date" \
    "status ignores .gitrepo when content matches upstream"

  unlike "$output" "\.gitrepo" \
    "status does not report .gitrepo as a local change"
}

{
  (
    cd "$OWNER/bar"
    add-new-files foo/real-change.txt
  ) &> /dev/null || die

  output=$(
    cd "$OWNER/bar"
    git subrepo status foo --diff
  )

  like "$output" "Push: *3 commits" \
    "status counts local content commits"

  like "$output" "Local diff:" \
    "diff flag prints local diff header for content change"

  like "$output" "real-change.txt" \
    "local diff lists the changed file"

  unlike "$output" "\.gitrepo" \
    "local diff excludes .gitrepo"
}

# Commits that only touch '.gitrepo' are subrepo bookkeeping rather than local
# content. A range can hold several of them and every one has to be left out.
{
  (
    cd "$OWNER/bar"
    git config --file foo/.gitrepo subrepo.cmdver "0.0.0-test"
    git add foo/.gitrepo
    git commit --quiet -m "first metadata-only change"
    git config --file foo/.gitrepo subrepo.cmdver "0.0.1-test"
    git add foo/.gitrepo
    git commit --quiet -m "second metadata-only change"
  ) &> /dev/null || die

  output=$(
    cd "$OWNER/bar"
    git subrepo status foo --log
  )

  like "$output" "Push: *3 commits" \
    "status leaves metadata-only commits out of the pending count"

  unlike "$output" "metadata-only change" \
    "status does not list metadata-only commits as pending"
}

done_testing 32

teardown
