#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" bar --method=rebase
  echo one > bar/one
  git add bar/one
  git commit -qm 'First pending change'
  echo two > bar/two
  git add bar/two
  git commit -qm 'Second pending change'
  cd "$OWNER/bar"
  echo incoming > incoming
  git add incoming
  git commit -qm 'Concurrent upstream change'
  git push -q
  cd "$repo"
  git subrepo pull bar
  git subrepo push bar
) > /dev/null
is "$(git --git-dir="$UPSTREAM/bar" show master:one)" one 'rebase join preserves the first local change'
is "$(git --git-dir="$UPSTREAM/bar" show master:two)" two 'rebase join preserves the second local change'
is "$(git --git-dir="$UPSTREAM/bar" show master:incoming)" incoming 'rebase join preserves the incoming change'
is "$(git --git-dir="$UPSTREAM/bar" log --format=%s master | grep -c '^First pending change$')" 1 \
  'ordinary rebase join does not consolidate or duplicate the first local contribution'
is "$(git --git-dir="$UPSTREAM/bar" log --format=%s master | grep -c '^Second pending change$')" 1 \
  'ordinary rebase join keeps the second local contribution separately'

(
  cd "$repo"
  git subrepo branch bar -f -F
  cd .git/tmp/subrepo/bar
  git checkout -qb custom-shared
  echo manual > manual
  git add manual
  git commit -qm 'Manually prepared shared change'
  cd "$repo"
  git subrepo commit bar custom-shared
  git subrepo push bar custom-shared
) > /dev/null
is "$(git --git-dir="$UPSTREAM/bar" show master:manual)" manual \
  'an explicit custom shared branch completes manual commit and push'

git -C "$OWNER/bar" fetch -q origin master
git -C "$OWNER/bar" push -q origin refs/remotes/origin/master:refs/heads/alternate
(cd "$repo" && git subrepo retarget bar -b alternate) > /dev/null
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.branch)" alternate \
  'retarget changes the branch without changing the prefix or original ancestry'
(
  cd "$repo"
  echo new > bar/new-branch
  git add bar/new-branch
  git commit -qm 'New branch contribution'
  git subrepo retarget bar -b new-shared
) > /dev/null
is "$(git --git-dir="$UPSTREAM/bar" show new-shared:new-branch)" new \
  'retarget can publish shared changes to a new branch'
is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.branch)" new-shared \
  'new branch publication records the new upstream branch'
is "$(git -C "$repo" status --porcelain)" "" 'manual, rebase and retarget sequence leaves a clean parent'

git --git-dir="$UPSTREAM/bar" update-ref refs/heads/resume-target refs/heads/new-shared
echo resumed > "$repo/bar/resumed"
git -C "$repo" add bar/resumed
git -C "$repo" commit -qm 'Pending retarget contribution'
before=$(git -C "$repo" rev-parse HEAD)
mkdir "$TMP/hooks"
cat > "$TMP/hooks/pre-commit" <<'EOF'
#!/bin/sh
if test -n "$(git diff --cached --name-only -- bar/.gitrepo)"; then
  exit 1
fi
EOF
chmod +x "$TMP/hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hooks"
status=0
(cd "$repo" && git subrepo retarget bar -b resume-target) > "$TMP/retarget-failure" 2>&1 || status=$?
is "$status" 1 'retarget stops when its local import cannot be recorded'
is "$(git --git-dir="$UPSTREAM/bar" ls-tree --name-only resume-target resumed)" "" \
  'a failed retarget import does not publish the pending contribution'
git -C "$repo" config --unset core.hooksPath
(cd "$repo" && git subrepo retarget bar -b resume-target) > "$TMP/retarget-retry" 2>&1
is "$(git --git-dir="$UPSTREAM/bar" show resume-target:resumed)" resumed \
  'retarget retry completes the intended publication'
is "$(git -C "$repo" rev-list --first-parent --count "$before..HEAD")" 2 \
  'retarget retry does not repeat its completed import phase'

done_testing
teardown
