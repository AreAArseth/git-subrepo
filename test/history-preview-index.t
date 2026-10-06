#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

for command in migrate retarget; do
  repo=$OWNER/preview-$command
  git clone -q "$UPSTREAM/foo" "$repo"
  history=legacy
  [[ $command != retarget ]] || history=prefixed
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared --history="$history") > /dev/null
  args=(migrate shared --history=prefixed --dry-run)
  [[ $command != retarget ]] || args=(retarget shared -b target --dry-run)

  for changes in clean unstaged staged; do
    for locked in false true; do
      git -C "$repo" reset --hard -q HEAD
      if [[ $changes != clean ]]; then
        echo 'Local change' >> "$repo/shared/Bar"
        [[ $changes != staged ]] || git -C "$repo" add shared/Bar
      fi
      # Make stat data stale deterministically without changing clean contents.
      touch -t 200001010000 "$repo/shared/Bar"
      cp "$repo/.git/index" "$TMP/index-before"
      if $locked; then
        printf 'Existing index lock\n' > "$repo/.git/index.lock"
        cp "$repo/.git/index.lock" "$TMP/lock-before"
      fi
      status=0
      (cd "$repo" && git subrepo "${args[@]}") > "$TMP/preview" 2>&1 || status=$?
      label="$command preview, $changes, locked=$locked"
      if [[ $changes == clean ]]; then
        is "$status" 0 "$label succeeds with stale index stat data"
        if [[ $command == migrate ]]; then
          like "$(cat "$TMP/preview")" 'Collaborators must use' "$label reports migration preview"
        else
          like "$(cat "$TMP/preview")" 'Preview only: the remote was checked' "$label reports retarget preview"
        fi
      else
        is "$status" 1 "$label refuses dirty work"
        reason='Unstaged changes'
        [[ $changes != staged ]] || reason='Index has changes'
        like "$(cat "$TMP/preview")" "Can't $command subrepo. $reason" "$label explains dirty work"
      fi
      ok "$(cmp -s "$repo/.git/index" "$TMP/index-before"; echo $?)" "$label preserves index bytes"
      if $locked; then
        ok "$(cmp -s "$repo/.git/index.lock" "$TMP/lock-before"; echo $?)" "$label preserves the existing lock"
        rm "$repo/.git/index.lock"
      else
        ok "$([[ ! -e "$repo/.git/index.lock" ]]; echo $?)" "$label leaves no index lock"
      fi
    done
  done
done

done_testing
teardown
