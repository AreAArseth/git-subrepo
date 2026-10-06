#!/usr/bin/env bash

set -e
source test/setup
use Test::More
git config --global gc.auto 0
git config --global maintenance.auto false
clone-foo-and-bar
repo=$OWNER/foo
# Increase this for a local benchmark of the same real-repository fixture.
count=${GIT_SUBREPO_LOG_TEST_COMMITS:-200}
[[ $count =~ ^[1-9][0-9]*$ ]] || die 'GIT_SUBREPO_LOG_TEST_COMMITS must be positive'
(
  cd "$OWNER/bar"
  original=$(git rev-parse HEAD)
  for ((i=1; i<=count; i++)); do
    message="Imported shared change $i"
    printf 'commit refs/heads/scale\ncommitter Test <test@example.invalid> %s +0000\ndata %s\n%s\n' \
      "$((1234567890 + i))" "${#message}" "$message"
    [[ $i != 1 ]] || printf 'from %s\n' "$original"
    printf 'M 100644 inline file\ndata %s\n%s\n\n' "${#i}" "$i"
  done | git fast-import --quiet
  git push -q origin scale
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" shared -b scale
) > /dev/null
before=$(git -C "$repo" rev-parse HEAD)
for group in '' --group-equivalent; do
  started=$SECONDS
  # shellcheck disable=SC2086
  (cd "$repo" && GIT_TRACE="$TMP/log.trace" git subrepo log shared --oneline $group) > "$TMP/history"
  elapsed=$((SECONDS - started))
  is "$(grep -c '\[imported\] Imported shared change ' "$TMP/history")" "$count" \
    "unbounded $group history retains all $count imported changes (${elapsed}s)"
  processes=$(grep -c 'trace: built-in:' "$TMP/log.trace")
  status=0
  [[ $processes -lt 150 ]] || status=1
  is "$status" 0 "display batches Git reads rather than spawning processes per entry ($processes)"
  rm "$TMP/log.trace"
  # shellcheck disable=SC2086
  (cd "$repo" && git subrepo log shared --oneline $group -- -5) > "$TMP/bounded"
  is "$(grep -Ec '^[0-9a-f]{12} \[(local|imported)\]' "$TMP/bounded")" 5 \
    'bounded history shows exactly five entries when none are equivalent'
done
is "$(git -C "$repo" rev-parse HEAD)" "$before" 'large history browsing never changes HEAD'
is "$(git -C "$repo" status --porcelain)" "" 'large history browsing preserves project files'

done_testing
teardown
