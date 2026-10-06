#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
clean=$(git -C "$OWNER/bar" rev-parse HEAD)

snapshot() {
  before=$(git -C "$repo" rev-parse HEAD)
  refs=$(git -C "$repo" show-ref)
  objects=$(git -C "$repo" count-objects -v)
  metadata=$(cat "$repo/"{a,z}/.gitrepo)
  cp "$repo/.git/index" "$TMP/index-before"
  files=$(cd "$repo/.git" && find . -type f | LC_ALL=C sort)
}

check-unchanged() {
  local label=$1 preview=$2
  is "$(git -C "$repo" rev-parse HEAD)" "$before" "$label preserves HEAD"
  is "$(git -C "$repo" show-ref)" "$refs" "$label preserves all refs"
  is "$(cat "$repo/"{a,z}/.gitrepo)" "$metadata" "$label preserves both tracking files"
  ok "$(cmp -s "$repo/.git/index" "$TMP/index-before"; echo $?)" "$label preserves index bytes"
  if $preview; then
    is "$(git -C "$repo" count-objects -v)" "$objects" "$label writes no objects"
    is "$(cd "$repo/.git" && find . -type f | LC_ALL=C sort)" "$files" \
      "$label creates no files in the Git directory"
  fi
}

for kind in nested quoted root removed-root shallow replacement incomplete; do
  (
    cd "$OWNER/bar"
    git checkout -qb "$kind" "$clean"
    case "$kind" in
      nested|quoted)
        path=nested
        [[ $kind != quoted ]] || path=$'nested\npath'
        mkdir "$path"
        echo metadata > "$path/.gitrepo"
        git add .
        git commit -qm 'Historical nested tracking metadata'
        git rm -qr "$path"
        git commit -qm 'Remove nested tracking metadata'
        ;;
      root|removed-root)
        echo metadata > .gitrepo
        git add .gitrepo
        git commit -qm 'Upstream root tracking metadata'
        if [[ $kind == removed-root ]]; then
          git rm -q .gitrepo
          git commit -qm 'Remove root tracking metadata'
        fi
        ;;
      incomplete)
        git commit -q --allow-empty -m 'Ancestor needed only by the later subrepo'
        git commit -q --allow-empty -m 'Later upstream tip'
        ;;
    esac
    git push -q origin "$kind"
  )
  repo=$OWNER/check-$kind
  git clone -q "$UPSTREAM/foo" "$repo"
  (
    cd "$repo"
    git subrepo clone "$UPSTREAM/bar" a --history=legacy
    git subrepo clone "$UPSTREAM/bar" z --history=legacy -b "$kind"
  ) > /dev/null
  if [[ $kind == root ]]; then
    # Legacy clone retains incoming root metadata. Restore a valid local record.
    cp "$repo/a/.gitrepo" "$repo/z/.gitrepo"
    git -C "$repo" config -f z/.gitrepo subrepo.branch "$kind"
    git -C "$repo" config -f z/.gitrepo subrepo.commit \
      "$(git -C "$OWNER/bar" rev-parse "$kind")"
    git -C "$repo" add z/.gitrepo
    git -C "$repo" commit -qm 'Record the upstream tip containing root metadata'
  fi
  tip=$(git -C "$repo" config -f z/.gitrepo subrepo.commit)
  reason='nested subrepo metadata'
  expected=1
  case "$kind" in
    root) reason='root tracking metadata' ;;
    removed-root)
      expected=0
      reason='Preview only'
      ;;
    shallow)
      printf '%s\n' "$tip" > "$repo/.git/shallow"
      reason='Complete upstream history is needed'
      ;;
    replacement)
      replacement=$(printf 'Replacement with the same content\n' |
        git -C "$repo" commit-tree "$tip^{tree}")
      git -C "$repo" replace "$tip" "$replacement"
      reason='History replacements are active'
      ;;
    incomplete)
      missing=$(git -C "$repo" rev-parse "$tip^")
      object=$repo/.git/objects/${missing:0:2}/${missing:2}
      [[ -f $object ]]
      rm "$object"
      reason='history.*could not be read'
      ;;
  esac
  # Stale stat data must not cause a read-only preview to refresh the index.
  touch -t 200001010000 "$repo/z/Bar"
  snapshot
  for mode in single all; do
    args=(migrate z --dry-run)
    [[ $mode != all ]] || args=(migrate --all --dry-run)
    status=0
    (cd "$repo" && git subrepo "${args[@]}") > "$TMP/preview" 2>&1 || status=$?
    label="$kind $mode preview"
    is "$status" "$expected" "$label applies rewrite eligibility checks"
    like "$(cat "$TMP/preview")" "$reason" "$label explains the result"
    check-unchanged "$label" true
  done
  if [[ $expected == 1 ]]; then
    git -C "$repo" update-index --refresh
    snapshot
    status=0
    (cd "$repo" && git subrepo migrate --all) > "$TMP/migrate" 2>&1 || status=$?
    is "$status" 1 "$kind bulk migration refuses ineligible history"
    like "$(cat "$TMP/migrate")" 'Migration checks failed. No subrepos were migrated' \
      "$kind bulk migration fails during preflight"
    # Real operations acquire a lease object; previews must not even do that.
    check-unchanged "$kind bulk migration" false
    is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo/a/map-1)" "" \
      "$kind bulk migration never starts rewriting the earlier valid subrepo"
  else
    (cd "$repo" && git subrepo migrate --all) > /dev/null
    is "$(git -C "$repo" config -f z/.gitrepo subrepo-v2.history)" prefixed \
      'historical root tracking metadata remains eligible for actual migration'
  fi
done

done_testing
teardown
