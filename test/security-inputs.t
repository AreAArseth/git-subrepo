#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

for mode in legacy prefixed; do
  repo=$OWNER/$mode
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar --history="$mode") > /dev/null
  if [[ $mode == legacy ]]; then section=subrepo; else section=subrepo-v2; fi
  cp "$repo/bar/.gitrepo" "$TMP/valid-$mode"
  for field in commit parent former remote branch; do
    [[ $mode == legacy || $field != former ]] || continue
    case "$field" in
      commit|parent|former) value="--output=$TMP/protected" ;;
      remote) value="--receive-pack=touch $TMP/executed" ;;
      branch) value='+HEAD:refs/heads/protected' ;;
    esac
    cp "$TMP/valid-$mode" "$repo/bar/.gitrepo"
    if [[ $field == former ]]; then
      git config -f "$repo/bar/.gitrepo" --unset subrepo.parent
    fi
    git config -f "$repo/bar/.gitrepo" "$section.$field" "$value"
    git -C "$repo" add bar/.gitrepo
    git -C "$repo" commit -qm "Invalid $field fixture"
    before=$(git -C "$repo" rev-parse HEAD)
    git -C "$repo" update-ref refs/heads/protected "$before"
    printf 'preserve these bytes\n' > "$TMP/protected"
    status=0
    (cd "$repo" && git subrepo status) > "$TMP/refused" 2>&1 || status=$?
    isnt "$status" 0 "$mode status refuses invalid $field metadata"
    like "$(cat "$TMP/refused")" 'invalid|Invalid' 'invalid metadata has an explicit diagnostic'
    is "$(cat "$TMP/protected")" 'preserve these bytes' 'revision parsing cannot truncate files'
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'refusal preserves project HEAD'
    if [[ $field == branch ]]; then
      status=0
      (cd "$repo" && git subrepo fetch bar) > "$TMP/refused" 2>&1 || status=$?
      isnt "$status" 0 "$mode refuses a destination-bearing fetch refspec"
      is "$(git -C "$repo" rev-parse protected)" "$before" 'fetch cannot overwrite unrelated refs'
    elif [[ $field == remote ]]; then
      git -C "$repo" branch subrepo/bar "$before"
      for operation in 'push bar subrepo/bar' 'retarget bar'; do
        read -r -a arguments <<< "$operation"
        status=0
        (cd "$repo" && git subrepo "${arguments[@]}") > "$TMP/refused" 2>&1 || status=$?
        isnt "$status" 0 "$mode refuses option-shaped remotes on $operation"
        test-exists "!$TMP/executed"
      done
      git -C "$repo" branch -D subrepo/bar > /dev/null
    fi
  done
  cp "$TMP/valid-$mode" "$repo/bar/.gitrepo"
  git -C "$repo" add bar/.gitrepo
  git -C "$repo" commit -qm 'Restore valid tracking'
  (cd "$repo" && git subrepo status bar) > "$TMP/status"
  like "$(cat "$TMP/status")" 'Git subrepo' "$mode still accepts valid tracking"

  git -C "$repo" remote add mapped-upstream "$UPSTREAM/bar"
  git -C "$repo" config remote.mapped-upstream.fetch 'refs/heads/master:refs/heads/protected'
  git config -f "$repo/bar/.gitrepo" "$section.remote" mapped-upstream
  git -C "$repo" add bar/.gitrepo
  git -C "$repo" commit -qm 'Named remote with unrelated fetch mapping'
  protected=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" update-ref refs/heads/protected "$protected"
  (cd "$repo" && git subrepo fetch bar) > "$TMP/fetch"
  is "$(git -C "$repo" rev-parse protected)" "$protected" \
    "$mode fetch ignores configured mappings to unrelated branches"

  (cd "$repo" && git subrepo clone mapped-upstream tagged --history="$mode" \
    --branch=refs/tags/A) > "$TMP/tag-clone"
  is "$(git config -f "$repo/tagged/.gitrepo" "$section.branch")" refs/tags/A \
    "$mode preserves explicit tag selectors"
  printf '%s\n' "$mode" > "$repo/tagged/security-change"
  git -C "$repo" add tagged/security-change
  git -C "$repo" commit -qm 'Shared contribution on an explicit tag selector'
  if [[ $mode == legacy ]]; then
    (cd "$repo" && git subrepo push tagged --force) > "$TMP/tag-push" 2>&1
    is "$(git --git-dir="$UPSTREAM/bar" show refs/tags/A:security-change)" "$mode" \
      'legacy publishes to the selected tag when explicitly forced'
  else
    tag_before=$(git --git-dir="$UPSTREAM/bar" rev-parse refs/tags/A)
    status=0
    (cd "$repo" && git subrepo push tagged --force) > "$TMP/tag-push" 2>&1 || status=$?
    is "$status" 1 'prefixed tag tracking still refuses forced publication'
    like "$(cat "$TMP/tag-push")" 'Force-pushing is not supported' \
      'prefixed tag refusal preserves the existing force-push policy'
    is "$(git --git-dir="$UPSTREAM/bar" rev-parse refs/tags/A)" "$tag_before" \
      'prefixed force-push refusal preserves the selected tag'
  fi
  is "$(git --git-dir="$UPSTREAM/bar" for-each-ref --format='%(refname)' refs/heads/refs/tags/A)" "" \
    "$mode does not turn a tag selector into an unrelated branch"
done

git -C "$OWNER/bar" tag -a annotated-security -m 'Annotated selector fixture'
git -C "$OWNER/bar" push -q origin refs/tags/annotated-security
repo=$OWNER/annotated-selector
git clone -q "$UPSTREAM/foo" "$repo"
(cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared \
  --branch=refs/tags/annotated-security) > /dev/null
before=$(git -C "$repo" rev-parse HEAD)
tag_before=$(git --git-dir="$UPSTREAM/bar" rev-parse refs/tags/annotated-security)
status=0
(cd "$repo" && git subrepo push shared) > "$TMP/annotated-noop" 2>&1 || status=$?
is "$status" 0 'unchanged annotated tag tracking is an up-to-date push'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'annotated tag no-op preserves project HEAD'
status=0
(cd "$repo" && git subrepo retarget shared --branch=refs/tags/annotated-security --dry-run) \
  > "$TMP/annotated-preview" 2>&1 || status=$?
is "$status" 0 'annotated tag retarget preview compares the peeled commit'
is "$(git --git-dir="$UPSTREAM/bar" rev-parse refs/tags/annotated-security)" "$tag_before" \
  'annotated tag operations preserve the tag object itself'

for mode in legacy prefixed; do
  for kind in lightweight annotated; do
    name=$mode-$kind-security
    if [[ $kind == annotated ]]; then
      git -C "$OWNER/bar" tag -a "$name" -m 'Plain annotated selector fixture'
    else
      git -C "$OWNER/bar" tag "$name"
    fi
    git -C "$OWNER/bar" push -q origin "refs/tags/$name"
    repo=$OWNER/plain-$name
    git clone -q "$UPSTREAM/foo" "$repo"
    (cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared \
      --history="$mode" --branch="$name") > /dev/null
    before=$(git -C "$repo" rev-parse HEAD)
    tag_before=$(git --git-dir="$UPSTREAM/bar" rev-parse "refs/tags/$name")
    status=0
    (cd "$repo" && git subrepo push shared) > "$TMP/plain-noop" 2>&1 || status=$?
    is "$status" 0 "$mode accepts an unchanged plain $kind tag selector"
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'plain tag no-op preserves project HEAD'
    if [[ $mode == legacy ]]; then
      printf '%s\n' "$name" > "$repo/shared/plain-tag-change"
      git -C "$repo" add shared/plain-tag-change
      git -C "$repo" commit -qm 'Shared contribution on a plain tag selector'
      status=0
      (cd "$repo" && git subrepo push shared --force) > "$TMP/plain-push" 2>&1 || status=$?
      is "$status" 0 "legacy can explicitly force publication to a plain $kind tag"
      is "$(git --git-dir="$UPSTREAM/bar" show "refs/tags/$name:plain-tag-change" 2>/dev/null)" \
        "$name" 'forced plain tag publication updates the selected tag'
    else
      status=0
      (cd "$repo" && git subrepo retarget shared --branch="$name" --dry-run) \
        > "$TMP/plain-preview" 2>&1 || status=$?
      is "$status" 0 "prefixed preview accepts a plain $kind tag"
      is "$(git --git-dir="$UPSTREAM/bar" rev-parse "refs/tags/$name")" "$tag_before" \
        'plain tag preview preserves the original tag object'
    fi
    is "$(git --git-dir="$UPSTREAM/bar" for-each-ref --format='%(refname)' "refs/heads/$name")" "" \
      'plain tag operations never create an unrelated branch'
  done

  name=ambiguous-$mode-security
  tip=$(git -C "$OWNER/bar" rev-parse HEAD)
  git -C "$OWNER/bar" push -q origin "$tip:refs/tags/$name"
  repo=$OWNER/$name
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared \
    --history="$mode" --branch="$name") > /dev/null
  printf 'ambiguous contribution\n' > "$repo/shared/ambiguous-change"
  git -C "$repo" add shared/ambiguous-change
  git -C "$repo" commit -qm 'Ambiguous selector contribution'
  before=$(git -C "$repo" rev-parse HEAD)
  refs_before=$(git -C "$repo" show-ref)
  branch_tip=$(printf 'Same-named branch history\n' |
    git --git-dir="$UPSTREAM/bar" commit-tree "$tip^{tree}" -p "$tip")
  git --git-dir="$UPSTREAM/bar" update-ref "refs/heads/$name" "$branch_tip"
  cp "$repo/.git/FETCH_HEAD" "$TMP/ambiguous-fetch-head"
  for operation in fetch pull push; do
    status=0
    (cd "$repo" && git subrepo "$operation" shared) > "$TMP/ambiguous-operation" 2>&1 || status=$?
    is "$status" 1 "$mode refuses $operation with an ambiguous plain selector"
    like "$(cat "$TMP/ambiguous-operation")" 'ambiguous|Ambiguous' 'selector ambiguity is diagnosed explicitly'
    is "$(git -C "$repo" show-ref)" "$refs_before" 'ambiguity refusal preserves local refs'
    unchanged=0
    cmp "$repo/.git/FETCH_HEAD" "$TMP/ambiguous-fetch-head" > /dev/null 2>&1 || unchanged=$?
    is "$unchanged" 0 'ambiguity refusal preserves FETCH_HEAD bytes'
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'ambiguity refusal preserves project HEAD'
    is "$(git -C "$repo" status --porcelain)" "" 'ambiguity refusal preserves project files'
  done
  status=0
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" refused \
    --history="$mode" --branch="$name") > "$TMP/ambiguous-clone" 2>&1 || status=$?
  is "$status" 1 "$mode refuses cloning an ambiguous plain selector"
  test-exists "!$repo/refused/"
  is "$(git --git-dir="$UPSTREAM/bar" rev-parse "refs/heads/$name")" "$branch_tip" \
    'ambiguous selector refusal preserves the advertised branch'
  is "$(git --git-dir="$UPSTREAM/bar" rev-parse "refs/tags/$name")" "$tip" \
    'ambiguous selector refusal preserves the advertised tag'
  status=0
  (cd "$repo" && git subrepo fetch shared --branch="refs/tags/$name") \
    > "$TMP/explicit-fetch" 2>&1 || status=$?
  is "$status" 0 "$mode still permits an explicit tag selector alongside a same-named branch"
  is "$(git -C "$repo" rev-parse refs/subrepo/shared/fetch)" "$tip" \
    'explicit tag fetch selects the tag commit rather than the same-named branch'
done

git clone -q --bare "$UPSTREAM/bar" "$UPSTREAM/hostile-head.git"
tip=$(git --git-dir="$UPSTREAM/hostile-head.git" rev-parse master)
name="--upload-pack=touch${TMP//\//_}"
git --git-dir="$UPSTREAM/hostile-head.git" update-ref "refs/heads/$name" "$tip"
git --git-dir="$UPSTREAM/hostile-head.git" symbolic-ref HEAD "refs/heads/$name"
git clone -q "$UPSTREAM/foo" "$OWNER/hostile-head"
status=0
(cd "$OWNER/hostile-head" && git subrepo clone "$UPSTREAM/hostile-head.git" bar) \
  > "$TMP/refused" 2>&1 || status=$?
isnt "$status" 0 'clone refuses an option-shaped advertised HEAD branch'
like "$(cat "$TMP/refused")" 'invalid|Invalid' 'hostile remote HEAD is diagnosed before fetching'
is "$(git -C "$OWNER/hostile-head" status --porcelain)" "" 'hostile HEAD refusal leaves the project clean'

done_testing
teardown
