#!/usr/bin/env bash

set -e
source test/setup
use Test::More

if ! git init -q --object-format=sha256 "$TMP/shared" 2> "$TMP/capability"; then
  plan skip_all 'This Git does not support SHA-256 repositories'
  teardown
  exit
fi
(
  cd "$TMP/shared"
  echo shared > file
  git add file
  git commit -qm 'SHA-256 upstream'
)
git clone -q --bare "$TMP/shared" "$UPSTREAM/sha256.git"
git init -q --object-format=sha256 "$TMP/parent"
(
  cd "$TMP/parent"
  echo parent > parent
  git add parent
  git commit -qm 'SHA-256 parent'
  git subrepo clone "$UPSTREAM/sha256.git" shared
  echo local >> shared/file
  git add shared/file
  git commit -qm 'SHA-256 local change'
  git subrepo push shared
) > /dev/null
mapped=$(git -C "$TMP/parent" config -f shared/.gitrepo subrepo-v2.mappedCommit)
is "${#mapped}" 64 'rewriting and metadata support native SHA-256 commit IDs'
is "$(git --git-dir="$UPSTREAM/sha256.git" show master:file)" $'shared\nlocal' \
  'SHA-256 repositories complete a real import and export'
is "$(git -C "$TMP/parent" rev-parse "$mapped:shared")" \
  "$(git --git-dir="$UPSTREAM/sha256.git" rev-parse 'master^{tree}')" 'SHA-256 mapped subtree is exact'
is "$(git -C "$TMP/parent" status --porcelain)" "" 'SHA-256 round trip leaves a clean parent'

done_testing
teardown
