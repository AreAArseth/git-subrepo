#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" bar
  echo first > bar/first
  git add .
  git commit -qm 'Same subject'
  git rev-parse HEAD > "$TMP/source"
  echo second > bar/second
  git add .
  git commit -qm 'Same subject'
  git subrepo push bar
  git subrepo log bar --group-equivalent --oneline > "$TMP/grouped"
) > /dev/null
is "$(grep -c '\[local\] Same subject' "$TMP/grouped")" 2 \
  'different changes with the same subject remain separate groups'
is "$(grep -c 'Same shared change' "$TMP/grouped")" 2 \
  'each source is grouped with only its proven imported representation'

(
  cd "$OWNER/bar"
  git pull -q
  echo unrelated > unrelated
  git add .
  git commit -qm 'Same subject'
  {
    printf 'tree %s\nparent %s\n' "$(git rev-parse 'HEAD^{tree}')" "$(git rev-parse HEAD^)"
    printf 'author Someone <someone@example.invalid> 1234567890 +0000\n'
    printf 'committer Someone <someone@example.invalid> 1234567890 +0000\n'
    printf 'git-subrepo-source 1 %s 626172\n\nSame subject\n' "$(cat "$TMP/source")"
  } > "$TMP/claimed"
  claimed=$(git hash-object -t commit -w "$TMP/claimed")
  git update-ref refs/heads/master "$claimed"
  git push -q
)
before=$(git -C "$repo" rev-parse HEAD)
(cd "$repo" && git subrepo log bar --fetch --incoming --oneline) > "$TMP/incoming"
like "$(cat "$TMP/incoming")" '\[upstream\] Same subject' 'incoming log shows fetched original upstream history'
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'fetching incoming log does not change parent HEAD'
is "$(git -C "$repo" status --porcelain)" "" 'incoming log preserves index and worktree'
(
  cd "$repo"
  echo pending > bar/pending
  git add bar/pending
  git commit -qm 'Pending local change'
  git subrepo status bar --log --diff > "$TMP/status-details"
)
like "$(cat "$TMP/status-details")" 'Local and incoming changes' \
  'status does not recommend pushing before incoming changes are integrated'
like "$(cat "$TMP/status-details")" 'Pending local change' 'v2 status retains local log details'
like "$(cat "$TMP/status-details")" 'Remote commits:' 'v2 status retains incoming log details'
like "$(cat "$TMP/status-details")" 'Local diff:' 'v2 status retains shared-only diff summaries'
(
  cd "$repo"
  git subrepo pull bar
  git subrepo log bar --group-equivalent --oneline > "$TMP/unverified"
) > /dev/null
mapped=$(git -C "$repo" config -f bar/.gitrepo subrepo-v2.mappedCommit)
status=0
grep -F "${mapped:0:12} [imported] Same subject" "$TMP/unverified" > /dev/null || status=$?
is "$status" 0 'a false source claim is not collapsed into an unrelated local commit'
is "$(grep -c 'Same shared change' "$TMP/unverified")" 2 \
  'unverified provenance does not create a third equivalence group'
status=0
(cd "$repo" && git subrepo log bar --group-equivalent -- --graph) > "$TMP/options" 2>&1 || status=$?
is "$status" 1 'unsupported grouped formatting fails explicitly'
like "$(cat "$TMP/options")" 'Remove --group-equivalent' 'formatting refusal gives the supported alternative'
(cd "$repo" && git subrepo log bar -- --format=%s) > "$TMP/custom"
like "$(cat "$TMP/custom")" 'Same subject' 'ungrouped custom Git formatting is passed through'
for quiet in -q --quiet; do
  status=0
  (cd "$repo" && git subrepo "$quiet" log bar -- --format=%s) > "$TMP/global" 2>&1 || status=$?
  is "$status" 0 "log accepts leading $quiet before pass-through Git options"
  is "$(cat "$TMP/global")" "$(cat "$TMP/custom")" \
    'leading global options preserve the exact custom log output'
done
is "$(cd "$repo" && git subrepo status bar --quiet)" bar \
  'quiet prefixed status prints the subrepo path'
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" another
  git subrepo clone "$UPSTREAM/bar" legacy --history=legacy
) > /dev/null
is "$(cd "$repo" && git subrepo status --quiet)" "$(printf 'another\nbar\nlegacy')" \
  'quiet mixed-mode status prints every path once with no labels'

for group in '' --group-equivalent; do
  for limit in '-5' '-n 5' '--max-count=5'; do
    read -r -a args <<< "$limit"
    status=0
    # shellcheck disable=SC2086
    (cd "$repo" && git subrepo log bar --oneline $group -- "${args[@]}") > "$TMP/bounded" 2>&1 || status=$?
    is "$status" 0 "bounded log accepts $group $limit"
    count=$(grep -Ec '^[0-9a-f]{12} \[(local|imported)\] ' "$TMP/bounded" || true)
    status=0
    [[ $count -gt 0 && $count -le 5 ]] || status=1
    is "$status" 0 'bounded output keeps labelled short entries'
    unlike "$(cat "$TMP/bounded")" 'Author:|Date:|^commit ' 'top-level oneline is honored'
  done
done
(cd "$repo" && git subrepo log bar --oneline -- --max-count=0) > "$TMP/zero"
is "$(cat "$TMP/zero")" "" 'zero count prints no entries'
(cd "$repo" && git subrepo log bar --oneline -- --no-decorate -1) > "$TMP/passthrough"
is "$(wc -l < "$TMP/passthrough" | tr -d ' ')" 1 'oneline composes with arbitrary Git options'
unlike "$(cat "$TMP/passthrough")" 'Author:|^commit ' 'custom passthrough does not lose oneline'
for invalid in '-n' '--max-count=bad'; do
  status=0
  (cd "$repo" && git subrepo log bar --group-equivalent -- "$invalid") > "$TMP/invalid" 2>&1 || status=$?
  is "$status" 1 "invalid count $invalid fails explicitly"
  like "$(cat "$TMP/invalid")" 'nonnegative history count' 'count diagnostic explains the input requirement'
done
(cd "$repo" && git subrepo status bar) > "$TMP/cached"
like "$(cat "$TMP/cached")" 'Remote not checked' 'offline status leads users to check remote freshness'
unlike "$(cat "$TMP/cached")" 'Original upstream commit:' 'ordinary status keeps raw IDs out of the summary'
(cd "$repo" && git subrepo status bar --fetch --verbose) > "$TMP/checked"
like "$(cat "$TMP/checked")" 'Remote checked' 'explicit fetch distinguishes current from cached status'
like "$(cat "$TMP/checked")" 'Original upstream commit:' 'verbose status retains tracking IDs'

(cd "$repo" && git subrepo branch bar --force) > /dev/null
worktree=$repo/.git/tmp/subrepo/bar
status=0
(cd "$repo" && git subrepo log bar --oneline -- -5) > "$TMP/clean-worktree-log" 2>&1 || status=$?
is "$status" 0 'clean shared worktree does not block browsing'
echo unfinished > "$worktree/unfinished"
before=$(git -C "$repo" rev-parse HEAD)
worktree_before=$(git -C "$worktree" status --porcelain)
for fetch in '' --fetch; do
  status=0
  # shellcheck disable=SC2086
  (cd "$repo" && git subrepo log bar --oneline $fetch -- -5) > "$TMP/worktree-log" 2>&1 || status=$?
  is "$status" 0 "history browsing $fetch works with a pending shared worktree"
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'browsing preserves parent HEAD'
  is "$(git -C "$worktree" status --porcelain)" "$worktree_before" 'browsing preserves pending work'
  is "$(cat "$worktree/unfinished")" unfinished 'browsing never removes worktree files'
done
status=0
(cd "$repo" && git subrepo pull bar) > "$TMP/blocked-pull" 2>&1 || status=$?
is "$status" 1 'a mutating pull still protects the pending shared worktree'
is "$(sed -n 's/^Shared worktree: //p' "$TMP/blocked-pull")" "$(cd "$worktree" && pwd -P)" \
  'blocked mutation identifies the worktree location'
like "$(cat "$TMP/blocked-pull")" 'unfinished' 'blocked mutation shows unfinished files'
unlike "$(cat "$TMP/blocked-pull")" 'Use the --force' 'blocked mutation does not recommend bypassing preservation'

done_testing
teardown
