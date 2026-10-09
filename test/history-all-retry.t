#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
for name in a b c; do
  git clone -q --bare "$UPSTREAM/bar" "$UPSTREAM/$name.git"
  (cd "$repo" && git subrepo clone "$UPSTREAM/$name.git" "$name") > /dev/null
  echo "$name" > "$repo/$name/new"
done
git -C "$repo" add a/new b/new c/new
git -C "$repo" commit -qm 'Independent shared changes'
mkdir "$TMP/hooks"
cat > "$TMP/hooks/pre-commit" <<'EOF'
#!/bin/sh
if test -n "$(git diff --cached --name-only -- b/.gitrepo)"; then
  exit 1
fi
EOF
chmod +x "$TMP/hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hooks"
status=0
(cd "$repo" && git subrepo push --all) > "$TMP/partial" 2>&1 || status=$?
is "$status" 1 'a failure partway through --all is not reported as complete'
like "$(cat "$TMP/partial")" 'git subrepo push --all' \
  'the retry instructions retain the original multi-repository request'
is "$(git --git-dir="$UPSTREAM/a.git" show master:new)" a 'the first shared repository was published'
is "$(git --git-dir="$UPSTREAM/b.git" show master:new)" b 'the failed local record follows a real second publication'
is "$(git --git-dir="$UPSTREAM/c.git" ls-tree --name-only master new)" "" \
  'the later shared repository has not been processed prematurely'
before=$(git -C "$repo" rev-parse HEAD)
first=$(cat "$repo/a/.gitrepo")
git -C "$repo" config --unset core.hooksPath
(cd "$repo" && git subrepo push --all) > "$TMP/retry" 2>&1
is "$(git --git-dir="$UPSTREAM/c.git" show master:new)" c \
  'journal retry continues the remaining --all operations'
is "$(cat "$repo/a/.gitrepo")" "$first" 'retry does not repeat an already completed integration'
is "$(git -C "$repo" rev-list --first-parent --count "$before..HEAD")" 2 \
  'retry creates only the resumed second record and the remaining third record'
is "$(git -C "$repo" status --porcelain)" "" 'completed --all retry leaves a clean parent'

done_testing
teardown
