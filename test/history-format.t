#!/usr/bin/env bash

set -e
source test/setup
use Test::More

clone-foo-and-bar
(cd "$OWNER/foo" && git subrepo clone "$UPSTREAM/bar") > /dev/null 2>&1 || die
gitrepo=$OWNER/foo/bar/.gitrepo

is "$(git config -f "$gitrepo" subrepo-v2.format || true)" 2 \
  'new subrepos use the complete v2 format'
is "$(git config -f "$gitrepo" subrepo-v2.history || true)" prefixed \
  'new subrepos default to prefixed history'
is "$(git config -f "$gitrepo" --get-regexp '^subrepo\.' || true)" "" \
  'new metadata does not retain legacy fields'
is "$(git config -f "$gitrepo" subrepo-v2.commit || true)" \
  "$(git -C "$OWNER/bar" rev-parse HEAD)" \
  'tracking identity remains the original upstream commit'

done_testing
teardown
