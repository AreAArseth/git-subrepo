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

done_testing 24

teardown
