#!/usr/bin/env bash

set -e
source test/setup
use Test::More

export TEST_REAL_GIT
TEST_REAL_GIT=$(command -v git)
mkdir "$TMP/recording-bin"
cat > "$TMP/recording-bin/git" <<'EOF'
#!/usr/bin/env bash
result=0
"$TEST_REAL_GIT" "$@" || result=$?
if [[ $result == 0 && ! -f $TEST_SWAP_DONE ]]; then
  swap=false
  if [[ $TEST_SWAP_BOUNDARY == discovery && $1 == ls-remote && $2 == --refs ]]; then
    swap=true
  elif [[ $TEST_SWAP_BOUNDARY == fetch && $1 == fetch ]]; then
    swap=true
  fi
  if $swap; then
    "$TEST_REAL_GIT" --git-dir="$TEST_SWAP_REMOTE" update-ref -d "$TEST_SWAP_FROM"
    "$TEST_REAL_GIT" --git-dir="$TEST_SWAP_REMOTE" update-ref "$TEST_SWAP_TO" "$TEST_SWAP_TIP"
    printf 'swapped\n' > "$TEST_SWAP_DONE"
  fi
fi
exit "$result"
EOF
chmod +x "$TMP/recording-bin/git"

for mode in legacy prefixed; do
  for operation in push retarget pull; do
    for scenario in discovery-heads discovery-tags fetch-heads fetch-tags; do
      boundary=${scenario%-*}
      kind=${scenario#*-}
      if [[ $kind == heads ]]; then other=tags; else other=heads; fi
      name=$mode-$operation-$boundary-$kind
      remote=$UPSTREAM/$name.git
      repo=$OWNER/$name
      git clone -q --bare "$UPSTREAM/bar" "$remote"
      upstream=$(git --git-dir="$remote" rev-parse master)
      git --git-dir="$remote" update-ref "refs/$kind/moving" "$upstream"
      git clone -q "$UPSTREAM/foo" "$repo"
      (cd "$repo" && git subrepo clone "$remote" shared --history="$mode" --branch=moving) > /dev/null
      if [[ $operation != pull ]]; then
        printf 'local shared change\n' > "$repo/shared/local-change"
        git -C "$repo" add shared/local-change
        git -C "$repo" commit -qm 'Shared contribution for namespace race'
      fi
      tree=$(git --git-dir="$remote" rev-parse "$upstream^{tree}")
      blob=$(printf 'unselected namespace content\n' | git --git-dir="$remote" hash-object -w --stdin)
      tree=$(
        { git --git-dir="$remote" ls-tree "$tree"; printf '100644 blob %s\tunselected-only\n' "$blob"; } |
          git --git-dir="$remote" mktree
      )
      unselected=$(printf 'Unselected namespace history\n' | git --git-dir="$remote" commit-tree "$tree" -p "$upstream")
      before=$(git -C "$repo" rev-parse HEAD)
      export TEST_SWAP_REMOTE=$remote TEST_SWAP_TIP=$unselected TEST_SWAP_BOUNDARY=$boundary
      export TEST_SWAP_FROM=refs/$kind/moving TEST_SWAP_TO=refs/$other/moving
      export TEST_SWAP_DONE=$TMP/swapped-$name
      options=("$operation" shared)
      if [[ $mode == legacy || $operation == pull ]]; then options+=(--force); fi
      status=0
      (cd "$repo" && PATH="$TMP/recording-bin:$PATH" bash "$GIT_SUBREPO_ROOT/lib/git-subrepo" "${options[@]}") \
        > "$TMP/race-output" 2>&1 || status=$?
      is "$(cat "$TEST_SWAP_DONE")" swapped "$name performs a real namespace swap at the transport boundary"
      is "$(git --git-dir="$remote" rev-parse "$TEST_SWAP_TO")" "$unselected" \
        "$name never publishes into the newly appeared namespace"
      selected=$(git -C "$repo" rev-parse --verify refs/subrepo/shared/fetch 2>/dev/null) || selected=
      isnt "$selected" "$unselected" "$name never imports the newly appeared namespace history"
      test-exists "!$repo/shared/unselected-only"
      if [[ $operation == pull ||
            ( $mode == legacy && $operation == retarget && $kind == tags ) ||
            ( $boundary == discovery &&
              ( $mode == legacy && $operation == retarget ||
                $mode == prefixed && $operation == push ) ) ]]; then
        is "$status" 1 "$name refuses when its exact ref disappears before a required fetch or leased push"
        is "$(git -C "$repo" rev-parse HEAD)" "$before" 'namespace race refusal preserves project HEAD'
        is "$(git -C "$repo" status --porcelain)" "" 'namespace race refusal preserves project files'
      else
        is "$status" 0 "$name can finish publication to the exact selected ref"
        is "$(git --git-dir="$remote" show "$TEST_SWAP_FROM:local-change" 2>/dev/null)" \
          'local shared change' 'publication retains the original namespace'
      fi
    done
  done
done

done_testing
teardown
