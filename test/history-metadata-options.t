#!/usr/bin/env bash

set -e
source test/setup
use Test::More

for history in prefixed legacy; do
  for operation in clone init; do
    for method in bogus ''; do
      repo=$OWNER/invalid-$history-$operation-${method:-empty}
      git clone -q "$UPSTREAM/init" "$repo"
      before=$(git -C "$repo" rev-parse HEAD)
      refs=$(git -C "$repo" show-ref)
      args=(doc)
      if [[ $operation == clone ]]; then args=("$UPSTREAM/bar" shared); fi
      status=0
      (cd "$repo" && git subrepo "$operation" "${args[@]}" --history="$history" --method="$method") \
        > "$TMP/refused" 2>&1 || status=$?
      is "$status" 1 "$history $operation rejects an invalid method (${method:-empty})"
      like "$(cat "$TMP/refused")" 'method.*merge.*rebase' 'method refusal lists the allowed values'
      is "$(git -C "$repo" rev-parse HEAD)" "$before" 'invalid method preserves parent HEAD'
      is "$(git -C "$repo" show-ref)" "$refs" 'invalid method preserves repository refs'
      is "$(git -C "$repo" status --porcelain)" "" 'invalid method leaves no files or metadata'
    done
  done
done

for operation in clone init; do
  for method in merge rebase; do
    repo=$OWNER/valid-$operation-$method
    git clone -q "$UPSTREAM/init" "$repo"
    args=(doc)
    prefix=doc
    if [[ $operation == clone ]]; then
      args=("$UPSTREAM/bar" shared)
      prefix=shared
    fi
    (cd "$repo" && git subrepo "$operation" "${args[@]}" -M "$method") > /dev/null
    is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.method)" "$method" \
      "$operation records the valid $method method"
    status=0
    (cd "$repo" && git subrepo status "$prefix") > "$TMP/status" 2>&1 || status=$?
    is "$status" 0 "$operation with $method remains readable by subsequent commands"
    is "$(git -C "$repo" status --porcelain)" "" "$operation with $method leaves a clean parent"
  done
done

git clone -q --bare "$UPSTREAM/bar" "$UPSTREAM/alternate"
original=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
git --git-dir="$UPSTREAM/bar" update-ref refs/heads/alternate "$original"
git --git-dir="$UPSTREAM/alternate" update-ref refs/heads/alternate "$original"
mkdir "$TMP/hooks"
cat > "$TMP/hooks/pre-push" <<'EOF'
#!/bin/sh
echo invoked > .git/push-invoked
exit 1
EOF
chmod +x "$TMP/hooks/pre-push"

for override in remote branch both squash; do
  repo=$OWNER/update-$override
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar) > /dev/null
  git -C "$repo" config core.hooksPath "$TMP/hooks"
  before=$(git -C "$repo" rev-parse HEAD)
  mapped=$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.mappedCommit)
  remote=$UPSTREAM/bar
  branch=master
  options=()
  if [[ $override != branch ]]; then
    remote=$UPSTREAM/alternate
    options+=(--remote "$remote")
  fi
  if [[ $override != remote ]]; then
    branch=alternate
    options+=(--branch "$branch")
  fi
  if [[ $override == squash ]]; then options+=(--squash); fi

  (cd "$repo" && git subrepo push bar "${options[@]}") > /dev/null
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$override without --update remains a no-op"
  is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.remote)" "$UPSTREAM/bar" \
    'a no-change push without --update preserves the recorded remote'
  is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.branch)" master \
    'a no-change push without --update preserves the recorded branch'

  status=0
  (cd "$repo" && git subrepo push bar "${options[@]}" --update) > "$TMP/update" 2>&1 || status=$?
  is "$status" 0 "$override --update succeeds without shared publication"
  like "$(cat "$TMP/update")" "Updated shared repository settings in 'bar/.gitrepo'." \
    'metadata-only push reports the settings update'
  unlike "$(cat "$TMP/update")" 'pushed to|Published shared files' \
    'metadata-only push does not claim publication'
  is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.remote)" "$remote" \
    "$override --update persists the requested remote"
  is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.branch)" "$branch" \
    "$override --update persists the requested branch"
  is "$(git -C "$repo" rev-list --first-parent --count "$before..HEAD")" 1 \
    '--update creates exactly one local metadata commit'
  is "$(git -C "$repo" show -s --format=%P HEAD)" "$before" \
    'the metadata-only commit has only the previous project parent'
  is "$(git -C "$repo" diff --name-only "$before" HEAD)" bar/.gitrepo \
    '--update changes only the tracking file'
  is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.commit)" "$original" \
    'metadata-only updates preserve the shared commit'
  is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.mappedCommit)" "$mapped" \
    'metadata-only updates preserve the imported history'
  is "$(git --git-dir="$remote" rev-parse "$branch")" "$original" \
    'metadata-only updates preserve the destination branch'
  is "$([[ -e $repo/.git/push-invoked ]] && echo invoked)" "" \
    'metadata-only updates never invoke git push'
  is "$(git -C "$repo" status --porcelain)" "" '--update leaves a clean project'

  updated=$(git -C "$repo" rev-parse HEAD)
  (cd "$repo" && git subrepo push bar "${options[@]}" --update) > /dev/null
  is "$(git -C "$repo" rev-parse HEAD)" "$updated" 'repeating matching overrides creates no commit'
done

git clone -q "$UPSTREAM/alternate" "$OWNER/incoming"
(
  cd "$OWNER/incoming"
  git checkout -qb incoming
  echo incoming > incoming
  git add incoming
  git commit -qm 'Incoming shared change'
  git push -q origin incoming
)
for branch in alternate incoming; do
  repo=$OWNER/retarget-$branch
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar) > /dev/null
  git -C "$repo" config core.hooksPath "$TMP/hooks"
  before=$(git -C "$repo" rev-parse HEAD)
  (cd "$repo" && git subrepo retarget bar --remote "$UPSTREAM/alternate" --branch "$branch") \
    > "$TMP/retarget" 2>&1
  is "$(git -C "$repo" rev-list --first-parent --count "$before..HEAD")" 1 \
    "$branch retarget records its import and settings in exactly one commit"
  is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.remote)" "$UPSTREAM/alternate" \
    'retarget persists the new remote'
  is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.branch)" "$branch" \
    'retarget persists the new branch'
  is "$([[ -e $repo/.git/push-invoked ]] && echo invoked)" "" \
    'retarget without outgoing content never invokes git push'
done

done_testing
teardown
