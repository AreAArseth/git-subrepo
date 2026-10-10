#!/usr/bin/env bash

source test/setup

use Test::More

clone-foo-and-bar

subrepo-clone-bar-into-foo

(
  cd "$OWNER/bar"
  git checkout -b branch1
  echo "branch1 change" > branch1.txt
  git add branch1.txt
  git commit -m "branch1 change"
  git push --set-upstream origin branch1
) &> /dev/null || die

(
  cd "$OWNER/foo"
  git subrepo retarget bar -b branch1
) &> /dev/null || die

gitrepo=$OWNER/foo/bar/.gitrepo
test-gitrepo-field branch branch1
is "$(git --git-dir="$UPSTREAM/bar" show branch1:branch1.txt)" "branch1 change" \
  'legacy retarget preserves the destination contribution'
is "$(git --git-dir="$UPSTREAM/bar" ls-tree --name-only branch1 Foo)" "" \
  'legacy retarget does not publish project-only files'

(
  cd "$OWNER/foo"
  git add bar/.gitrepo
  git commit -m "Update bar subrepo branch"
) &> /dev/null || die

(
  cd "$OWNER/foo"
  git subrepo pull bar
) &> /dev/null || die

for kind in lightweight annotated; do
  for selector in plain explicit; do
    name=retarget-$kind-$selector
    remote=$UPSTREAM/$name
    repo=$OWNER/$name
    git clone -q --bare "$UPSTREAM/bar" "$remote"
    if [[ $kind == annotated ]]; then
      git --git-dir="$remote" tag -a "$name" -m 'Retarget annotated tag fixture'
    else
      git --git-dir="$remote" tag "$name"
    fi
    git clone -q "$UPSTREAM/foo" "$repo"
    (cd "$repo" && git subrepo clone "$remote" shared --history=legacy) > /dev/null
    printf '%s\n' "$name" > "$repo/shared/tag-contribution"
    git -C "$repo" add shared/tag-contribution
    git -C "$repo" commit -qm 'Local contribution for tag retarget'
    branch=$name
    [[ $selector != explicit ]] || branch=refs/tags/$name
    before=$(git -C "$repo" rev-parse HEAD)
    refs_before=$(git -C "$repo" show-ref)
    tag_before=$(git --git-dir="$remote" rev-parse "refs/tags/$name")
    status=0
    (cd "$repo" && git subrepo retarget shared --branch="$branch" --update) \
      > "$TMP/tag-retarget-refused" 2>&1 || status=$?
    is "$status" 1 "$kind/$selector tag retarget requires explicit force"
    like "$(cat "$TMP/tag-retarget-refused")" 'requires.*--force' 'tag retarget explains the update policy'
    is "$(git -C "$repo" status --porcelain)" "" 'unforced tag retarget preserves project files'
    is "$(git -C "$repo" show-ref)" "$refs_before" 'unforced tag retarget preserves local refs'
    is "$(git --git-dir="$remote" rev-parse "refs/tags/$name")" "$tag_before" \
      'unforced tag retarget preserves the tag object'
    status=0
    (cd "$repo" && GIT_TRACE="$TMP/$name-trace" \
      git subrepo retarget shared --branch="$branch" --update --force) \
      > "$TMP/tag-retarget-forced" 2>&1 || status=$?
    is "$status" 0 "$kind/$selector tag retarget publishes with explicit force"
    is "$(git --git-dir="$remote" show "refs/tags/$name:tag-contribution" 2>/dev/null)" "$name" \
      'forced tag retarget publishes the shared contribution'
    is "$(git --git-dir="$remote" ls-tree --name-only "refs/tags/$name" Foo)" "" \
      'forced tag retarget does not publish project-only files'
    is "$(git --git-dir="$remote" for-each-ref --format='%(refname)' "refs/heads/$name")" "" \
      'forced tag retarget never creates a same-named branch'
    like "$(cat "$TMP/$name-trace")" "--force-with-lease=refs/tags/$name:$tag_before" \
      'forced tag retarget binds publication to the observed tag object'
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'tag retarget preserves project HEAD'
  done
done

remote=$UPSTREAM/tag-retarget-race
repo=$OWNER/tag-retarget-race
git clone -q --bare "$UPSTREAM/bar" "$remote"
git --git-dir="$remote" tag -a race-tag -m 'Original tag for retarget lease'
original=$(git --git-dir="$remote" rev-parse master)
alternate=$(printf 'Concurrent tag update\n' |
  git --git-dir="$remote" commit-tree "$original^{tree}" -p "$original")
git clone -q "$UPSTREAM/foo" "$repo"
(cd "$repo" && git subrepo clone "$remote" shared --history=legacy) > /dev/null
printf 'local contribution\n' > "$repo/shared/tag-contribution"
git -C "$repo" add shared/tag-contribution
git -C "$repo" commit -qm 'Local contribution for tag lease refusal'
cat > "$repo/.git/hooks/post-checkout" <<EOF
#!/usr/bin/env bash
git --git-dir="$remote" update-ref refs/tags/race-tag "$alternate"
EOF
chmod +x "$repo/.git/hooks/post-checkout"
before=$(git -C "$repo" rev-parse HEAD)
status=0
(cd "$repo" && git subrepo retarget shared --branch=race-tag --force) \
  > "$TMP/tag-retarget-race" 2>&1 || status=$?
is "$status" 1 'forced tag retarget refuses a concurrent tag change'
like "$(cat "$TMP/tag-retarget-race")" 'stale info' 'concurrent tag changes fail the explicit lease'
is "$(git --git-dir="$remote" rev-parse refs/tags/race-tag)" "$alternate" \
  'forced tag retarget preserves the concurrent update'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'tag lease failure preserves project HEAD'

done_testing

teardown
