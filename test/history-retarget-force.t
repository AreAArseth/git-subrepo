#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

# Interrupt after the real import and cleanup, before publication.
cat > "$TMP/stop-before-push" <<'EOF'
#!/usr/bin/env bash
source "$GIT_SUBREPO_ROOT/lib/git-subrepo"
history:push() {
  kill -KILL "$$"
}
main "$@"
EOF

for mode in clean interrupted; do
  for destination in existing missing divergent; do
    label=$mode-$destination
    repo=$OWNER/$label
    remote=$UPSTREAM/$label
    git clone -q "$UPSTREAM/foo" "$repo"
    git clone -q --bare "$UPSTREAM/bar" "$remote"
    (cd "$repo" && git subrepo clone "$remote" shared) > /dev/null
    original_tip=$(git --git-dir="$remote" rev-parse master)
    if [[ $destination != missing ]]; then
      git --git-dir="$remote" update-ref refs/heads/target "$original_tip"
    fi
    if [[ $destination == divergent ]]; then
      git clone -q -b target "$remote" "$OWNER/incoming-$label"
      echo incoming > "$OWNER/incoming-$label/incoming"
      git -C "$OWNER/incoming-$label" add incoming
      git -C "$OWNER/incoming-$label" commit -qm 'Incoming destination contribution'
      git -C "$OWNER/incoming-$label" push -q
    fi
    destination_tip=$(git --git-dir="$remote" rev-parse --verify refs/heads/target 2>/dev/null || true)
    echo local > "$repo/shared/local"
    git -C "$repo" add shared/local
    git -C "$repo" commit -qm 'Local shared contribution'
    if [[ $mode == interrupted ]]; then
      # A manual branch ensures even a missing destination has an import.
      (cd "$repo" && git subrepo branch shared) > /dev/null
      worktree=$repo/.git/tmp/subrepo/shared
      echo manual > "$worktree/manual"
      git -C "$worktree" add manual
      git -C "$worktree" commit -qm 'Manual shared contribution'
      before=$(git -C "$repo" rev-parse HEAD)
      remote_before=$(git --git-dir="$remote" show-ref)
      status=0
      (cd "$repo" && bash "$TMP/stop-before-push" retarget shared -b target --force) \
        > "$TMP/$label-stop" 2>&1 || status=$?
      is "$status" 137 "$label: interrupted immediately before publication"
      imported=$(git -C "$repo" rev-parse HEAD)
      is "$(git -C "$repo" rev-list --first-parent --count "$before..HEAD")" 1 \
        "$label: import completed exactly once"
      is "$(git --git-dir="$remote" show-ref)" "$remote_before" "$label: interruption did not publish"
      is "$(git config -f "$repo/.git/subrepo-integration" operation.phase)" retarget-import \
        "$label: import remains resumable"
      test-exists "!$worktree/"
    fi

    status=0
    (cd "$repo" && GIT_TRACE="$TMP/$label-trace" git subrepo retarget shared -b target --force) \
      > "$TMP/$label-result" 2>&1 || status=$?
    is "$status" 0 "$label: retarget --force succeeds"
    unlike "$(cat "$TMP/$label-result")" 'Force-pushing is not supported' \
      "$label: retarget is not treated as a public force push"
    if [[ $status != 0 ]]; then
      continue
    fi
    is "$(git --git-dir="$remote" show target:local)" local "$label: local content is published"
    is "$(cat "$repo/shared/local")" local "$label: local content remains in the parent"
    is "$(git --git-dir="$remote" rev-parse master)" "$original_tip" "$label: original branch is unchanged"
    if [[ $destination_tip ]]; then
      is "$(git --git-dir="$remote" merge-base "$destination_tip" target)" "$destination_tip" \
        "$label: publication preserves destination history"
    fi
    if [[ $destination == divergent ]]; then
      is "$(git --git-dir="$remote" show target:incoming)" incoming "$label: incoming content is published"
      is "$(cat "$repo/shared/incoming")" incoming "$label: incoming content reaches the parent"
    fi
    if [[ $mode == interrupted ]]; then
      is "$(git -C "$repo" rev-parse HEAD^1)" "$imported" "$label: retry adds only the publication record"
      is "$(git --git-dir="$remote" show target:manual)" manual "$label: retry publishes the manual contribution"
      is "$(cat "$repo/shared/manual")" manual "$label: manual contribution remains in the parent"
    fi
    transport=$(grep 'built-in: git push ' "$TMP/$label-trace" || true)
    like "$transport" 'built-in: git push .*:refs/heads/target' "$label: real Git transport was exercised"
    unlike "$transport" ' --force| -f | \+' "$label: transport has no force option or forced refspec"
    is "$(git -C "$repo" config -f shared/.gitrepo subrepo-v2.branch)" target "$label: metadata records destination"
    is "$(git -C "$repo" config -f shared/.gitrepo subrepo-v2.commit)" \
      "$(git --git-dir="$remote" rev-parse target)" "$label: metadata records publication"
    is "$(git -C "$repo" status --porcelain)" "" "$label: parent is clean"
    test-exists "!$repo/.git/subrepo-integration" "!$repo/.git/subrepo-pending/shared/push"
  done
done

repo=$OWNER/public-force
remote=$UPSTREAM/public-force
git clone -q "$UPSTREAM/foo" "$repo"
git clone -q --bare "$UPSTREAM/bar" "$remote"
(cd "$repo" && git subrepo clone "$remote" shared) > /dev/null
echo local > "$repo/shared/local"
git -C "$repo" add shared/local
git -C "$repo" commit -qm 'Local content must not be force-pushed'
before=$(git -C "$repo" rev-parse HEAD)
remote_before=$(git --git-dir="$remote" show-ref)
status=0
(cd "$repo" && git subrepo push shared --force) > "$TMP/public-force" 2>&1 || status=$?
is "$status" 1 'public push --force remains unsupported'
like "$(cat "$TMP/public-force")" 'Force-pushing is not supported' 'public force push explains its refusal'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'public force push refusal preserves parent HEAD'
is "$(git --git-dir="$remote" show-ref)" "$remote_before" 'public force push refusal never publishes'

done_testing
teardown
