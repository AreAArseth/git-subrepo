#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

tree=$(git -C "$OWNER/bar" rev-parse 'HEAD^{tree}')
printf 'Raw message \351\n\nwithout final newline' > "$TMP/body"
{
  printf 'tree %s\n' "$tree"
  printf 'author Exact Author <author@example.invalid> 1234567890 +0530\n'
  printf 'committer Exact Committer <committer@example.invalid> 1234567891 -0330\n'
  printf 'encoding ISO-8859-1\n'
  printf 'custom-header preserved\n continued value\n'
  printf 'gpgsig signature that must not survive rewriting\n continuation\n'
  printf '\n'
  cat "$TMP/body"
} > "$TMP/original"
original=$(git -C "$OWNER/bar" hash-object -t commit -w "$TMP/original")
git -C "$OWNER/bar" update-ref refs/heads/raw "$original"
git -C "$OWNER/bar" push -q origin raw

(
  cd "$OWNER/foo"
  git subrepo clone "$UPSTREAM/bar" shared -b raw
) > /dev/null 2>&1
mapped=$(git -C "$OWNER/foo" config -f shared/.gitrepo subrepo-v2.mappedCommit)
git -C "$OWNER/foo" cat-file commit "$mapped" > "$TMP/mapped"
tail -c "$(wc -c < "$TMP/body" | tr -d ' ')" "$TMP/mapped" > "$TMP/mapped-body"
status=0
cmp "$TMP/body" "$TMP/mapped-body" || status=$?
is "$status" 0 'rewrite preserves non-UTF8 message bytes and missing final newline'
is "$(grep '^author ' "$TMP/mapped")" "$(grep '^author ' "$TMP/original")" \
  'rewrite preserves exact author identity and timezone'
is "$(grep '^committer ' "$TMP/mapped")" "$(grep '^committer ' "$TMP/original")" \
  'rewrite preserves exact committer identity and timezone'
is "$(grep '^encoding ' "$TMP/mapped")" 'encoding ISO-8859-1' 'encoding is preserved'
is "$(grep '^gpgsig ' "$TMP/mapped" || true)" "" 'invalidated signature header is removed'
is "$(grep '^ continuation' "$TMP/mapped" || true)" "" 'signature continuations are removed'
is "$(grep '^custom-header ' "$TMP/mapped")" 'custom-header preserved' 'unknown valid header is preserved'
is "$(grep '^ continued value' "$TMP/mapped")" ' continued value' 'unknown header continuation is preserved'
is "$(git -C "$OWNER/foo" rev-parse "$mapped:shared")" "$tree" 'mapped subtree is exact'
is "$(git -C "$OWNER/foo" show -s --format=%P "$mapped")" "" 'upstream root remains a root'

expected_tree=$(printf '040000 tree %s\tshared\0' "$tree" |
  git -C "$OWNER/foo" mktree -z)
{
  printf 'tree %s\n' "$expected_tree"
  printf 'author Exact Author <author@example.invalid> 1234567890 +0530\n'
  printf 'committer Exact Committer <committer@example.invalid> 1234567891 -0330\n'
  printf 'encoding ISO-8859-1\n'
  printf 'custom-header preserved\n continued value\n'
  printf 'git-subrepo-rewrite 1 %s 736861726564\n\n' "$original"
  cat "$TMP/body"
} > "$TMP/golden"
is "$mapped" "$(git -C "$OWNER/foo" hash-object -t commit "$TMP/golden")" \
  'complete raw object matches an independently assembled golden fixture'

git clone -q "$UPSTREAM/foo" "$OWNER/other"
(
  cd "$OWNER/other"
  git subrepo clone "$UPSTREAM/bar" shared -b raw
  git subrepo clone "$UPSTREAM/bar" different -b raw
) > /dev/null 2>&1
is "$(git -C "$OWNER/other" config -f shared/.gitrepo subrepo-v2.mappedCommit)" "$mapped" \
  'independent parent repositories produce identical mapped IDs'
isnt "$(git -C "$OWNER/other" config -f different/.gitrepo subrepo-v2.mappedCommit)" "$mapped" \
  'different prefixes have distinct mapped IDs'

next=$(printf 'An empty upstream change\n' |
  git -C "$OWNER/bar" commit-tree "$tree" -p "$original")
git -C "$OWNER/bar" update-ref refs/heads/raw "$next"
git -C "$OWNER/bar" push -q origin raw
(cd "$OWNER/foo" && git subrepo pull shared) > /dev/null
new_mapped=$(git -C "$OWNER/foo" config -f shared/.gitrepo subrepo-v2.mappedCommit)
is "$(git -C "$OWNER/foo" rev-parse "$new_mapped^")" "$mapped" \
  'incremental import preserves the existing mapped object identity'
is "$(git -C "$OWNER/foo" for-each-ref --format='%(objectname)' refs/subrepo/shared/map-1 | wc -l | tr -d ' ')" 2 \
  'extending the upstream by one commit adds exactly one mapping'

done_testing
teardown
