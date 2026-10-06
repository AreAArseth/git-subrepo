#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo="$OWNER/project:quoted\"\\name"
linked=$OWNER/linked
mv "$OWNER/foo" "$repo"
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" shared
  echo first >> shared/Bar
  git add shared/Bar
  git commit -qm 'First local contribution'
  mkdir shared/nested
  echo second > shared/nested/second
  git add shared/nested/second
  git commit -qm 'Second local contribution'
  echo unrelated > project-only
  git add project-only
  git commit -qm 'Unrelated project commit'
  git worktree add -qb linked "$linked"
  cd "$OWNER/bar"
  echo incoming > incoming
  git add incoming
  git commit -qm 'Incoming shared contribution'
  git push -q
  cd "$repo"
  git subrepo fetch shared
) > /dev/null

snapshot() {
  find "$repo" "$linked" "${object_store:-$repo/.git/objects}" -type f |
    LC_ALL=C sort -u | while IFS= read -r file; do cksum "$file"; done
}

for directory in "$repo" "$linked"; do
  # Detailed status describes committed history, without refreshing dirty or
  # stale indexes and without disturbing an existing index lock.
  echo staged >> "$directory/shared/Bar"
  git -C "$directory" add shared/Bar
  echo unstaged >> "$directory/shared/Bar"
  echo untracked > "$directory/untracked"
  touch -t 200001010000 "$directory/project-only"
  index=$(git -C "$directory" rev-parse --git-path index)
  [[ $index == /* ]] || index=$directory/$index
  echo 'Existing index lock' > "$index.lock"
done

for directory in "$repo" "$linked"; do
  for detail in --log --diff --verbose combined; do
    args=("$detail")
    [[ $detail != combined ]] || args=(--log --log-limit=1 --diff)
    before=$(snapshot)
    (cd "$directory" && git subrepo status shared "${args[@]}") > "$TMP/status" 2>&1
    output=$(cat "$TMP/status")
    label="${directory##*/} $detail"
    like "$output" 'Local and incoming changes' "$label preserves the summary"
    if [[ $detail != --diff ]]; then
      like "$output" 'Second local contribution' "$label shows projected local history"
      like "$output" 'Incoming shared contribution' "$label shows cached incoming history"
      unlike "$output" 'Unrelated project commit' "$label omits project-only history"
    fi
    if [[ $detail == --diff || $detail == combined ]]; then
      like "$output" 'Local diff:' "$label shows the local diff"
      like "$output" 'nested/second' "$label uses upstream-relative paths"
      like "$output" 'Remote diff:' "$label shows the cached incoming diff"
    fi
    if [[ $detail == combined ]]; then
      like "$output" 'and 1 more commit' "$label preserves the log limit"
    fi
    is "$(snapshot)" "$before" "$label preserves objects, refs, indexes, locks and files with no scratch leaks"
  done
done

# Object lookup must retain existing on-disk alternates, including from a
# linked worktree whose object directory lives in the common Git directory.
object_store=$OWNER/existing-objects
mv "$repo/.git/objects" "$object_store"
mkdir -p "$repo/.git/objects/info"
printf '%s\n' "$object_store" > "$repo/.git/objects/info/alternates"
for directory in "$repo" "$linked"; do
  before=$(snapshot)
  (cd "$directory" && git subrepo status shared --log --diff) > "$TMP/status" 2>&1
  like "$(cat "$TMP/status")" 'Second local contribution' 'detailed status reads existing alternate objects'
  is "$(snapshot)" "$before" 'alternate object stores remain byte-for-byte unchanged'
done

real_git=$(command -v git)
export HISTORY_STATUS_REAL_GIT=$real_git
mkdir "$TMP/bin"
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ ${HISTORY_STATUS_FAILURE:-} &&
      $1 == hash-object && $2 == -t && $3 == commit && $4 == -w ]]; then
  echo 'Injected export failure' >&2
  case "$HISTORY_STATUS_FAILURE" in
    fail) exit 1 ;;
    term) kill -TERM "$GIT_SUBREPO_RUNNING"; exit 1 ;;
    kill) kill -KILL "$GIT_SUBREPO_RUNNING"; exit 1 ;;
  esac
fi
exec "$HISTORY_STATUS_REAL_GIT" "$@"
EOF
chmod +x "$TMP/bin/git"
for outcome in fail term; do
  before=$(snapshot)
  status=0
  (cd "$linked" && PATH="$TMP/bin:$PATH" HISTORY_STATUS_FAILURE=$outcome \
    git-subrepo status shared --log --diff) > "$TMP/failure" 2>&1 || status=$?
  expected=1
  [[ $outcome != term ]] || expected=143
  is "$status" "$expected" "$outcome propagates a failure after preparing projected trees"
  like "$(cat "$TMP/failure")" 'Injected export failure' "$outcome reached the export write boundary"
  is "$(snapshot)" "$before" "$outcome removes scratch objects and preserves repository state"
  (cd "$linked" && git subrepo status shared --log --diff) > "$TMP/status" 2>&1
  like "$(cat "$TMP/status")" 'Second local contribution' "$outcome permits a successful read-only retry"
  is "$(snapshot)" "$before" "$outcome retry leaves no objects, refs, indexes or scratch files behind"
done

for directory in "$repo" "$linked"; do
  index=$(git -C "$directory" rev-parse --git-path index)
  [[ $index == /* ]] || index=$directory/$index
  rm "$index.lock"
done
before=$(snapshot)
status=0
(cd "$linked" && PATH="$TMP/bin:$PATH" HISTORY_STATUS_FAILURE=kill \
  git-subrepo status shared --log --diff) > "$TMP/failure" 2>&1 || status=$?
is "$status" 137 'an abruptly killed export leaves an abandoned reader operation'
(cd "$linked" && git subrepo status shared --log --diff) > "$TMP/status" 2>&1
like "$(cat "$TMP/status")" 'Second local contribution' 'a retry recovers an interrupted detailed status'
is "$(snapshot)" "$before" 'dead-reader recovery removes scratch objects without publishing them'

for outcome in fail term; do
  before_refs=$(git -C "$repo" for-each-ref --format='%(refname) %(objectname)')
  before_indexes=$(git -C "$repo" hash-object .git/index .git/worktrees/linked/index)
  status=0
  (cd "$linked" && PATH="$TMP/bin:$PATH" HISTORY_STATUS_FAILURE=$outcome \
    git-subrepo status shared --fetch --log --diff) > "$TMP/failure" 2>&1 || status=$?
  expected=1
  [[ $outcome != term ]] || expected=143
  is "$status" "$expected" "fetching status propagates export $outcome"
  like "$(cat "$TMP/failure")" 'Injected export failure' "fetching status reaches export before $outcome"
  is "$(git -C "$repo" for-each-ref --format='%(refname) %(objectname)')" "$before_refs" \
    "fetching status $outcome releases its durable writer lease with scratch exports active"
  is "$(git -C "$repo" hash-object .git/index .git/worktrees/linked/index)" "$before_indexes" \
    "fetching status $outcome preserves both worktree indexes"
  is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
    "fetching status $outcome removes its scratch objects and process lock"
done

# The local object environment must end with this subrepo's rendering: a later
# --fetch in the same invocation must retain newly fetched objects permanently.
(
  cd "$repo"
  git reset --hard -q HEAD
  rm untracked
  git subrepo clone "$UPSTREAM/foo" other
  git clone -q "$UPSTREAM/foo" "$OWNER/publisher"
  cd "$OWNER/publisher"
  echo 'second remote' > second-remote
  git add second-remote
  git commit -qm 'Second remote contribution'
  git push -q
  cd "$repo"
  git subrepo status shared other --fetch --log --diff > "$TMP/fetched-status"
) > /dev/null
incoming=$(git -C "$OWNER/publisher" rev-parse HEAD)
is "$(git -C "$repo" rev-parse refs/subrepo/other/fetch)" "$incoming" \
  'a later subrepo fetch updates its permanent cached ref'
is "$(git -C "$repo" cat-file -p "$incoming:second-remote")" 'second remote' \
  'a later subrepo fetch retains its objects after status scratch cleanup'
like "$(cat "$TMP/fetched-status")" 'Second remote contribution' \
  'multi-subrepo status renders both local and freshly fetched history'
is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
  'multi-subrepo fetching status leaves no operation scratch or lock'

done_testing
teardown
