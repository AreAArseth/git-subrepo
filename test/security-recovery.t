#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar) > /dev/null
before=$(git -C "$repo" rev-parse HEAD)
upstream=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
snapshot=$(git -C "$repo" rev-parse "$upstream^{tree}")
candidate=$(git -C "$repo" commit-tree "$snapshot" -p "$before" -p "$upstream" \
  -m 'Same shared tree and upstream ancestry with private project history')
pending=$repo/.git/subrepo-pending/bar/push
mkdir -p "$(dirname "$pending")"
for forged in "+$upstream" "$before" "$candidate"; do
  git config -f "$pending" push.commit "$forged"
  git config -f "$pending" push.parent "$before"
  git config -f "$pending" push.previous "$upstream"
  git config -f "$pending" push.request 'push bar '
  git config -f "$pending" push.worktree "$(git -C "$repo" rev-parse --show-toplevel)"
  git config -f "$pending" push.projectBranch refs/heads/master
  git config -f "$pending" push.remote "$UPSTREAM/bar"
  git config -f "$pending" push.remoteBranch master
  status=0
  (cd "$repo" && git subrepo push bar) > "$TMP/refused" 2>&1 || status=$?
  isnt "$status" 0 'a forged pending candidate is refused'
  like "$(cat "$TMP/refused")" 'invalid commit ID|pending.*candidate|pending.*history' \
    'pending refusal verifies the candidate rather than an unrelated precondition'
  is "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" "$upstream" \
    'refusal never publishes or force-pushes the forged history'
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'forged pending record cannot change project HEAD'
  is "$(git -C "$repo" status --porcelain)" "" 'forged pending record preserves project files'
done
rm "$pending"

journal=$repo/.git/subrepo-integration
git config -f "$journal" operation.parent "$before"
git config -f "$journal" operation.branch refs/heads/master
git config -f "$journal" operation.tree "$(git -C "$repo" mktree < /dev/null)"
git config -f "$journal" operation.mapped ""
git config -f "$journal" operation.directory bar
git config -f "$journal" operation.request 'clean bar '
git config -f "$journal" operation.edit false
git config -f "$journal" operation.phase complete
printf 'Unprepared recovery commit\n' > "$journal.message"
status=0
(cd "$repo" && git subrepo clean bar) > "$TMP/refused" 2>&1 || status=$?
isnt "$status" 0 'a hand-written integration journal is refused'
like "$(cat "$TMP/refused")" 'prepared|recovery record' 'untrusted recovery has an explicit diagnostic'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'a forged journal cannot create a project commit'
is "$(git -C "$repo" status --porcelain)" "" 'a forged journal cannot reset the index or worktree'
rm "$journal" "$journal.message"

mkdir "$TMP/hooks"
cat > "$TMP/hooks/pre-commit" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$TMP/hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hooks"
(
  cd "$OWNER/bar"
  printf 'incoming\n' > incoming
  git add incoming
  git commit -qm 'Incoming update to interrupt'
  git push -q
)
status=0
(cd "$repo" && git subrepo pull bar) > "$TMP/interrupted" 2>&1 || status=$?
is "$status" 1 'real hook failure leaves a recoverable prepared integration'
test-exists "$journal"
git -C "$repo" config --unset core.hooksPath
cp "$journal" "$TMP/saved-journal"
cp "$journal.message" "$TMP/saved-message"
for tamper in tree directory mapped message; do
  cp "$TMP/saved-journal" "$journal"
  cp "$TMP/saved-message" "$journal.message"
  case "$tamper" in
    tree) git config -f "$journal" operation.tree "$(git -C "$repo" mktree < /dev/null)" ;;
    directory) git config -f "$journal" operation.directory ../outside ;;
    mapped) git config -f "$journal" operation.mapped "$before" ;;
    message) printf 'Altered recovery message\n' > "$journal.message" ;;
  esac
  status=0
  (cd "$repo" && git subrepo pull bar) > "$TMP/refused" 2>&1 || status=$?
  isnt "$status" 0 "tampered recovery $tamper is refused"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'tampering cannot change project HEAD'
  is "$(git -C "$repo" status --porcelain)" "" 'tampering cannot change project files'
done
cp "$TMP/saved-journal" "$journal"
cp "$TMP/saved-message" "$journal.message"
ln -s "$repo/.git" "$TMP/git-directory-alias"
is "$(cd "$repo" && GIT_DIR="$TMP/git-directory-alias" history:integration-ref)" \
  "$(cd "$repo" && history:integration-ref)" \
  'prepared recovery has the same worktree identity through a Git-directory alias'
ln -s "$repo" "$OWNER/project-alias"
(cd "$OWNER/project-alias" && git subrepo pull bar) > "$TMP/resumed" 2>&1
is "$(cat "$repo/bar/incoming")" incoming 'the original prepared integration can still resume'
test-exists "!$journal"
is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo-integrations/)" "" \
  'successful recovery removes its prepared-operation binding'

mkdir "$repo/tagged"
printf 'shared\n' > "$repo/tagged/content"
git -C "$repo" add tagged/content
git -C "$repo" commit -qm 'Shared content for initial tag publication'
(cd "$repo" && git subrepo init tagged --remote="$UPSTREAM/bar" \
  --branch=refs/tags/recovered) > /dev/null
before=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" config core.hooksPath "$TMP/hooks"
status=0
(cd "$repo" && git subrepo push tagged) > "$TMP/tag-interrupted" 2>&1 || status=$?
is "$status" 1 'hook failure interrupts local recording after initial tag publication'
published=$(git --git-dir="$UPSTREAM/bar" rev-parse refs/tags/recovered)
test-exists "$journal"
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'interrupted tag recording preserves project HEAD'
git -C "$repo" config --unset core.hooksPath
status=0
(cd "$repo" && git subrepo push tagged) > "$TMP/tag-resumed" 2>&1 || status=$?
is "$status" 0 'tag publication recovery checks the actual selected tag'
is "$(git --git-dir="$UPSTREAM/bar" rev-parse refs/tags/recovered)" "$published" \
  'tag recovery does not republish a different commit'
is "$(git config -f "$repo/tagged/.gitrepo" subrepo-v2.commit)" "$published" \
  'tag recovery records the published commit locally'
is "$(git config -f "$repo/tagged/.gitrepo" subrepo-v2.branch)" refs/tags/recovered \
  'tag recovery retains the explicit selector'
test-exists "!$journal"

done_testing
teardown
