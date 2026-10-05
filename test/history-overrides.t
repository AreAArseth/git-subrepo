#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
git clone -q --bare "$UPSTREAM/bar" "$UPSTREAM/alternate"
git clone -q "$UPSTREAM/alternate" "$OWNER/alternate"
original=$(git --git-dir="$UPSTREAM/bar" rev-parse master)
(
  cd "$OWNER/alternate"
  git checkout -qb incoming
  echo incoming > incoming
  git add incoming
  git commit -qm 'Change from temporary remote'
  git push -q origin incoming
)

for operation in pull push; do
  for persist in no yes; do
    repo=$OWNER/$operation-$persist
    git clone -q "$UPSTREAM/foo" "$repo"
    (cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar) > /dev/null
    options=()
    if [[ $persist == yes ]]; then options=(--update); fi
    if [[ $operation == pull ]]; then
      branch=incoming
    else
      branch=publish-$persist
      git --git-dir="$UPSTREAM/alternate" update-ref "refs/heads/$branch" "$original"
      echo "$persist" > "$repo/bar/published"
      git -C "$repo" add bar/published
      git -C "$repo" commit -qm 'Change for temporary remote'
    fi
    (
      cd "$repo"
      git subrepo "$operation" bar --remote "$UPSTREAM/alternate" --branch "$branch" "${options[@]}"
    ) > /dev/null
    if [[ $operation == pull ]]; then
      is "$(cat "$repo/bar/incoming")" incoming 'pull uses the temporary remote and branch'
    else
      is "$(git --git-dir="$UPSTREAM/alternate" show "$branch:published")" "$persist" \
        'push publishes to the temporary remote and branch'
    fi
    expected_remote=$UPSTREAM/bar
    expected_branch=master
    if [[ $persist == yes ]]; then
      expected_remote=$UPSTREAM/alternate
      expected_branch=$branch
    fi
    is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.remote)" "$expected_remote" \
      "$operation persists its remote override only with --update ($persist)"
    is "$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.branch)" "$expected_branch" \
      "$operation persists its branch override only with --update ($persist)"
    is "$(git --git-dir="$UPSTREAM/bar" rev-parse master)" "$original" \
      'an overridden operation does not publish to the recorded upstream'
    is "$(git -C "$repo" status --porcelain)" "" 'override synchronization leaves a clean parent'
  done
done

done_testing
teardown
