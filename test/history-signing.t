#!/usr/bin/env bash

set -e
source test/setup
use Test::More

version=$(git version | cut -d ' ' -f3)
major=${version%%.*}
minor=${version#*.}; minor=${minor%%.*}
if (( major < 2 || (major == 2 && minor < 34) )); then
  plan skip_all 'Real SSH commit signing requires Git 2.34 or newer'
  teardown
  exit
fi
command -v ssh-keygen > /dev/null || {
  plan skip_all 'Real SSH commit signing requires ssh-keygen'
  teardown
  exit
}

clone-foo-and-bar
ssh-keygen -q -t ed25519 -N '' -f "$TMP/signing-key"
printf 'test@example.com %s\n' "$(cat "$TMP/signing-key.pub")" > "$TMP/allowed-signers"
for repo in "$OWNER/foo" "$OWNER/bar"; do
  git -C "$repo" config gpg.format ssh
  git -C "$repo" config user.signingkey "$TMP/signing-key"
  git -C "$repo" config gpg.ssh.allowedSignersFile "$TMP/allowed-signers"
  git -C "$repo" config commit.gpgsign true
done
(
  cd "$OWNER/bar"
  echo signed > signed
  git add .
  git commit -qm 'Signed upstream change'
  git push -q
  cd "$OWNER/foo"
  git subrepo clone "$UPSTREAM/bar" bar
) > /dev/null
status=0
git -C "$OWNER/foo" verify-commit HEAD > "$TMP/verify" 2>&1 || status=$?
is "$status" 0 'the parent integration has a valid configured signature'
mapped=$(git -C "$OWNER/foo" config -f bar/.gitrepo subrepo-v2.mappedCommit)
is "$(git -C "$OWNER/foo" cat-file commit "$mapped" | grep '^gpgsig ' || true)" "" \
  'rewritten browsing commit does not retain an invalid original signature'
original=$(git -C "$OWNER/foo" config -f bar/.gitrepo subrepo-v2.commit)
status=0
git -C "$OWNER/foo" verify-commit "$original" > "$TMP/original-verify" 2>&1 || status=$?
is "$status" 0 'original signed upstream object remains independently verifiable'

done_testing
teardown
