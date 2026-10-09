#!/usr/bin/env bash

set -e
source test/setup
use Test::More

clone-foo-and-bar
(cd "$OWNER/foo" && git subrepo clone "$UPSTREAM/bar") > /dev/null 2>&1
A=$OWNER/foo
B=$OWNER/second
(
  git init -q "$B"
  cd "$B"
  echo 'Independent parent' > parent.txt
  git add parent.txt
  git commit -qm 'Independent parent'
  git subrepo clone "$UPSTREAM/bar" bar
) > /dev/null 2>&1

mapped=$(git -C "$A" config -f bar/.gitrepo subrepo-v2.mappedCommit)
is "$(git -C "$A" show -s --format=%P HEAD | wc -w | tr -d ' ')" 2 \
  'initial import has two parents'
is "$(git -C "$A" rev-parse "$mapped:bar")" \
  "$(git -C "$OWNER/bar" rev-parse 'HEAD^{tree}')" \
  'rewritten tree contains the exact upstream tree under the shared prefix'

for cycle in 1 2 3; do
  (
    cd "$A"
    echo "A $cycle" > "bar/from-a-$cycle"
    echo "Parent $cycle" >> Foo
    git add .
    git -c user.name=Alice -c user.email=alice@example.invalid commit -qm "A shared and parent change $cycle"
    git subrepo push bar
    cd "$B"
    git subrepo pull bar
    echo "B $cycle" > "bar/from-b-$cycle"
    git add .
    git -c user.name=Bob -c user.email=bob@example.invalid commit -qm "B shared change $cycle"
    git subrepo push bar
    cd "$A"
    git subrepo pull bar
  ) > "$TMP/cycle-$cycle.log" 2>&1
  is "$(cat "$A/bar/from-b-$cycle")" "B $cycle" \
    "round trip $cycle preserves B's shared change"
  is "$(cat "$B/bar/from-a-$cycle")" "A $cycle" \
    "round trip $cycle preserves A's mixed-commit shared change"
done

is "$(git -C "$B" log -1 --format=%an -- bar/from-a-3)" Alice \
  'ordinary path-filtered Git history retains the imported author'
like "$(git -C "$B" log --full-history --format=%s -- bar/from-a-3)" 'A shared and parent change 3' \
  'full path history includes the individual imported contribution'
like "$(git -C "$B" blame --line-porcelain bar/from-a-3)" 'author Alice' \
  'ordinary blame attributes unchanged imported lines to the shared author'
is "$(git -C "$A" diff-tree --no-commit-id --name-only -r HEAD^1 HEAD)" \
  $'bar/.gitrepo\nbar/from-b-3' 'first-parent integration diff contains only intended shared changes'

is "$(git --git-dir="$UPSTREAM/bar" ls-tree -r --name-only master | grep -E '(^|/)\.gitrepo$|^bar/|^Foo$' || true)" "" \
  'upstream contains no tracking metadata, prefix, or parent-only files'
is "$(git -C "$A" config -f bar/.gitrepo subrepo-v2.format)" 2 \
  'repeated pushes and pulls retain v2 metadata'
is "$(git -C "$A" status --porcelain)" "" 'parent A stays clean'
is "$(git -C "$B" status --porcelain)" "" 'parent B stays clean'

before=$(git -C "$A" rev-parse HEAD)
(
  cd "$A"
  git subrepo pull bar
  git subrepo push bar
) > /dev/null 2>&1
is "$(git -C "$A" rev-parse HEAD)" "$before" 'up-to-date operations create no commits'

(
  cd "$A"
  git subrepo log bar --group-equivalent --oneline
) > "$TMP/grouped" 2>&1
like "$(cat "$TMP/grouped")" 'Same shared change' \
  'explicit grouping links proven local and imported shared changes'

git init -q --bare "$TMP/parent-a.git"
git -C "$A" push -q "$TMP/parent-a.git" master
git clone -q --no-local "$TMP/parent-a.git" "$OWNER/fresh"
is "$(git -C "$OWNER/fresh" for-each-ref --format='%(refname)' refs/subrepo)" "" \
  'ordinary fresh clone has no special subrepo refs'
(
  cd "$OWNER/fresh"
  git subrepo log bar --oneline
  git subrepo clean bar --force
  git subrepo branch bar -F
  git subrepo clean bar
  echo 'Fresh clone change' > bar/fresh
  git add .
  git commit -qm 'Fresh clone contribution'
  git subrepo push bar
  cd "$B"
  git subrepo pull bar
) > "$TMP/fresh.log" 2>&1
is "$(cat "$B/bar/fresh")" 'Fresh clone change' \
  'fresh clone rebuilds mappings and completes a real export/import round trip'

done_testing
teardown
