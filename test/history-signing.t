#!/usr/bin/env bash

set -e
source test/setup
use Test::More

version=$(git version | cut -d ' ' -f3)
major=${version%%.*}
minor=${version#*.}; minor=${minor%%.*}
if (( major < 2 || (major == 2 && minor < 34) )); then
  teardown
  plan skip_all 'Real SSH commit signing requires Git 2.34 or newer'
fi
command -v ssh-keygen > /dev/null || {
  teardown
  plan skip_all 'Real SSH commit signing requires ssh-keygen'
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
  git subrepo clone "$UPSTREAM/bar" bar --method=rebase
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

(
  cd "$OWNER/foo"
  echo 'local signed edit' > bar/signed
  git add .
  git commit -qm 'Signed local contribution'
  cd "$OWNER/bar"
  echo incoming > unrelated
  git add .
  git commit -qm 'Signed unrelated incoming edit'
  git push -q
  cd "$OWNER/foo"
  git subrepo pull bar
) > "$TMP/rebase.log" 2>&1
status=0
git -C "$OWNER/foo" verify-commit subrepo/bar > "$TMP/replay-verify" 2>&1 || status=$?
is "$status" 0 'completed replay can contain genuinely signed local commits'
replay=$(git -C "$OWNER/foo" rev-parse subrepo/bar)
base=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
git clone -q --no-local --single-branch --branch master "$OWNER/foo" "$OWNER/fresh"
status=0
git -C "$OWNER/fresh" cat-file -e "$replay^{commit}" 2>/dev/null || status=$?
isnt "$status" 0 'fresh clone does not have the original signed replay'
(
  cd "$OWNER/bar"
  echo followup > unrelated
  git add .
  git commit -qm 'Signed unrelated follow-up'
  git push -q
  cd "$OWNER/fresh"
  git subrepo pull bar
  git subrepo push bar
) > "$TMP/fresh-replay.log" 2>&1
is "$(git --git-dir="$UPSTREAM/bar" show master:signed)" 'local signed edit' \
  'fresh clone restores and publishes the signed replay content'
status=0
git --git-dir="$UPSTREAM/bar" merge-base --is-ancestor "$base" master || status=$?
is "$status" 0 'restored replay retains exact signed upstream ancestry'
is "$(git --git-dir="$UPSTREAM/bar" log -1 --format=%s -- signed)" 'Signed local contribution' \
  'restored signed replay preserves the individual local commit message'

done_testing
teardown
