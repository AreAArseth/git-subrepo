#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
for name in a b c; do
  git clone -q --bare "$UPSTREAM/bar" "$UPSTREAM/$name.git"
  (cd "$repo" && git subrepo clone "$UPSTREAM/$name.git" "$name" --history=legacy) > /dev/null
done
before=$(git -C "$repo" rev-parse HEAD)
refs=$(git -C "$repo" show-ref)
metadata=$(cat "$repo/"{a,b,c}/.gitrepo)
upstream=$(git --git-dir="$UPSTREAM/b.git" show-ref)
status=0
(cd "$repo" && git subrepo migrate -a --dry-run) > "$TMP/ready-preview" 2>&1 || status=$?
is "$status" 0 'short --all accepts migration preview'
for name in a b c; do
  like "$(cat "$TMP/ready-preview")" "Migrate '$name/'" "preview checks $name"
  is "$(grep -c "Migrate '$name/'" "$TMP/ready-preview")" 1 "preview reports $name only once"
done
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'bulk preview preserves HEAD'
is "$(git -C "$repo" show-ref)" "$refs" 'bulk preview preserves refs'
is "$(cat "$repo/"{a,b,c}/.gitrepo)" "$metadata" 'bulk preview preserves metadata bytes'
status=0
(cd "$repo" && git subrepo migrate a --all --dry-run) > "$TMP/extra-arg" 2>&1 || status=$?
is "$status" 1 'bulk migration rejects a simultaneous subdir argument'
like "$(cat "$TMP/extra-arg")" 'either a subdir or --all' 'argument error explains the two alternatives'

for name in b c; do
  echo "$name" > "$repo/$name/new"
done
git -C "$repo" add b/new c/new
git -C "$repo" commit -qm 'Committed changes not synchronized with the shared upstreams'
before=$(git -C "$repo" rev-parse HEAD)
refs=$(git -C "$repo" show-ref)
status=0
(cd "$repo" && git subrepo migrate b --dry-run) > "$TMP/single-blocked" 2>&1 || status=$?
is "$status" 1 'single migration rejects committed unsynchronized content'
like "$(cat "$TMP/single-blocked")" 'committed shared content differs from its recorded upstream commit' \
  'diagnostic distinguishes committed changes from a dirty working tree'
like "$(cat "$TMP/single-blocked")" 'git subrepo pull b' 'diagnostic gives the pull command'
like "$(cat "$TMP/single-blocked")" 'git subrepo push b' 'diagnostic gives the push command'
like "$(cat "$TMP/single-blocked")" 'fetch alone does not synchronize' \
  'diagnostic distinguishes fetching history from synchronizing content'
for option in --dry-run ''; do
  status=0
  (cd "$repo" && git subrepo migrate --all ${option:+"$option"}) > "$TMP/blocked-all" 2>&1 || status=$?
  is "$status" 1 "bulk migration $option fails when a subrepo is blocked"
  like "$(cat "$TMP/blocked-all")" "'b/'" "bulk migration $option reports the first blocked subrepo"
  like "$(cat "$TMP/blocked-all")" "'c/'" "bulk migration $option also reports the later blocked subrepo"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "blocked bulk migration $option preserves HEAD"
  is "$(git -C "$repo" show-ref)" "$refs" "blocked bulk migration $option preserves refs"
  is "$(cat "$repo/"{a,b,c}/.gitrepo)" "$metadata" "blocked bulk migration $option preserves all metadata"
done
is "$(git --git-dir="$UPSTREAM/b.git" show-ref)" "$upstream" 'previews and blocked migrations do not publish'
is "$(git -C "$repo" status --porcelain)" "" 'blocked migrations leave the clean parent unchanged'

for name in b c; do
  (cd "$repo" && git subrepo push "$name" && git subrepo pull "$name") > /dev/null
done
(cd "$repo" && git subrepo migrate a) > /dev/null
before=$(git -C "$repo" rev-parse HEAD)
first=$(cat "$repo/a/.gitrepo")
status=0
(cd "$repo" && git subrepo migrate --all --dry-run) > "$TMP/mixed-preview" 2>&1 || status=$?
is "$status" 0 'bulk preview accepts mixed legacy and already migrated subrepos'
like "$(cat "$TMP/mixed-preview")" "'a/' already uses prefixed history" \
  'bulk preview identifies an already migrated subrepo'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'mixed preview preserves HEAD'
mkdir "$TMP/hooks"
cat > "$TMP/hooks/pre-commit" <<'EOF'
#!/bin/sh
if test -n "$(git diff --cached --name-only -- c/.gitrepo)"; then
  exit 1
fi
EOF
chmod +x "$TMP/hooks/pre-commit"
git -C "$repo" config core.hooksPath "$TMP/hooks"
status=0
(cd "$repo" && git subrepo migrate --all) > "$TMP/hook-error" 2>&1 || status=$?
is "$status" 1 'a real hook failure during bulk migration is reported'
is "$(git -C "$repo" config -f b/.gitrepo subrepo-v2.history)" prefixed \
  'integration failure retains an earlier completed migration'
is "$(git -C "$repo" config -f c/.gitrepo subrepo.cmdver)" "$VERSION" \
  'integration failure preserves the failed subrepo legacy metadata'
is "$(git -C "$repo" status --porcelain)" "" 'hook failure restores command-owned working-tree changes'
git -C "$repo" config --unset core.hooksPath
(cd "$repo" && git subrepo migrate --all) > /dev/null
is "$(cat "$repo/a/.gitrepo")" "$first" 'bulk migration leaves an already migrated subrepo unchanged'
is "$(git -C "$repo" rev-list --first-parent --count "$before..HEAD")" 2 \
  'bulk migration creates one integration for each remaining legacy subrepo'
for name in a b c; do
  is "$(git -C "$repo" config -f "$name/.gitrepo" subrepo-v2.history)" prefixed \
    "bulk migration upgrades $name"
done
is "$(git -C "$repo" diff --name-only "$before" HEAD)" $'b/.gitrepo\nc/.gitrepo' \
  'bulk migration changes only tracking metadata'
after=$(git -C "$repo" rev-parse HEAD)
(cd "$repo" && git subrepo migrate -a) > /dev/null
is "$(git -C "$repo" rev-parse HEAD)" "$after" 'repeating bulk migration is a no-op'
is "$(git -C "$repo" status --porcelain)" "" 'bulk migration leaves a clean working tree'

done_testing
teardown
