#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
origin=$OWNER/foo
repo="$OWNER/project:quoted\"\\name"
linked=$OWNER/linked
(
  cd "$origin"
  git subrepo clone "$UPSTREAM/bar" shared
  echo single > shared/single
  git add shared/single
  git commit -qm 'Single contribution'
  git subrepo push shared
  echo first > shared/first
  git add shared/first
  git commit -qm 'First aggregate contribution'
  echo second > shared/second
  git add shared/second
  git commit -qm 'Second aggregate contribution'
  git subrepo push shared --squash
  git checkout -qb unmerged
  echo branch > shared/branch-only
  git add shared/branch-only
  git commit -qm 'Unmerged branch contribution'
  git checkout -q master
  # A transport clone contains reachable history, not the otherwise unreachable
  # projected trees left by earlier writer commands in the originating repo.
  git clone -q --no-local "$origin" "$repo"
  git -C "$repo" worktree add -qb linked "$linked"
) > /dev/null

snapshot() {
  find "$repo" "$linked" | LC_ALL=C sort
  find "$repo" "$linked" -type f | LC_ALL=C sort |
    while IFS= read -r file; do cksum "$file"; done
}

for directory in "$repo" "$linked"; do
  echo staged >> "$directory/shared/single"
  git -C "$directory" add shared/single
  echo unstaged >> "$directory/shared/single"
  echo untracked > "$directory/untracked"
  touch -t 200001010000 "$directory/shared/first"
  index=$(git -C "$directory" rev-parse --git-path index)
  [[ $index == /* ]] || index=$directory/$index
  echo 'Existing index lock' > "$index.lock"
done

for mode in plain oneline custom grouped grouped-full bounded zero; do
  args=()
  case "$mode" in
    oneline) args=(--oneline) ;;
    custom) args=(-- --format=%H:%s) ;;
    grouped) args=(--group-equivalent --oneline) ;;
    grouped-full) args=(--group-equivalent) ;;
    bounded) args=(--group-equivalent --oneline -- -5) ;;
    zero) args=(--group-equivalent --oneline -- --max-count=0) ;;
  esac
  (cd "$origin" && git subrepo log shared "${args[@]}") > "$TMP/expected"
  for directory in "$repo" "$linked"; do
    before=$(snapshot)
    (cd "$directory" && git subrepo log shared "${args[@]}") > "$TMP/log" 2>&1
    is "$(cat "$TMP/log")" "$(cat "$TMP/expected")" \
      "$mode in ${directory##*/} preserves exact history output in a fresh clone"
    is "$(snapshot)" "$before" \
      "$mode in ${directory##*/} preserves objects, refs, indexes, locks and files without scratch leaks"
    if [[ $mode == grouped ]]; then
      is "$(grep -c 'Same shared change' "$TMP/log")" 2 \
        'fresh-clone grouping proves both single-source and aggregate equivalence'
      like "$(cat "$TMP/log")" '\[local\] Second aggregate contribution' \
        'the aggregate uses its final local contribution as representative'
      unlike "$(cat "$TMP/log")" '\[local\] First aggregate contribution' \
        'the earlier proven aggregate member is not displayed separately'
    fi
  done
done

# Passing through Git's alternate-ref selection must not add the main object
# store as an alternate, which would unexpectedly select its unmerged refs.
before=$(snapshot)
(cd "$repo" && git log --alternate-refs --format=%H:%s HEAD -- ':(literal)shared') > "$TMP/expected"
(cd "$repo" && git subrepo log shared -- --alternate-refs --format=%H:%s) > "$TMP/log"
is "$(cat "$TMP/log")" "$(cat "$TMP/expected")" 'custom alternate-ref selection preserves native Git semantics'
unlike "$(cat "$TMP/log")" 'Unmerged branch contribution' 'custom history does not gain unrelated branch tips'
is "$(snapshot)" "$before" 'custom alternate-ref selection remains read-only'

real_git=$(command -v git)
export HISTORY_LOG_REAL_GIT=$real_git
mkdir "$TMP/bin"
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ ${HISTORY_LOG_FAILURE:-} && $1 == log && ${7:-} == -z ]]; then
  echo 'Injected history rendering failure' >&2
  case "$HISTORY_LOG_FAILURE" in
    fail) exit 1 ;;
    term) kill -TERM "$GIT_SUBREPO_RUNNING"; exit 1 ;;
  esac
fi
exec "$HISTORY_LOG_REAL_GIT" "$@"
EOF
chmod +x "$TMP/bin/git"
for outcome in fail term; do
  before=$(snapshot)
  status=0
  (cd "$linked" && PATH="$TMP/bin:$PATH" HISTORY_LOG_FAILURE=$outcome \
    git-subrepo log shared --group-equivalent --oneline) > "$TMP/failure" 2>&1 || status=$?
  expected=1
  [[ $outcome != term ]] || expected=143
  is "$status" "$expected" "$outcome propagates after equivalence tree projection"
  like "$(cat "$TMP/failure")" 'Injected history rendering failure' \
    "$outcome reaches the final rendering boundary"
  is "$(snapshot)" "$before" "$outcome removes projected objects and preserves repository state"
  (cd "$linked" && git subrepo log shared --group-equivalent --oneline) > "$TMP/log"
  like "$(cat "$TMP/log")" 'Same shared change' "$outcome permits a successful grouped retry"
  is "$(snapshot)" "$before" "$outcome retry remains read-only"
done

for directory in "$repo" "$linked"; do
  index=$(git -C "$directory" rev-parse --git-path index)
  [[ $index == /* ]] || index=$directory/$index
  rm "$index.lock"
done

for outcome in success fail term; do
  (
    cd "$OWNER/bar"
    git pull -q
    echo "$outcome" > incoming
    git add incoming
    git commit -qm "Incoming $outcome contribution"
    git push -q
  )
  incoming=$(git -C "$OWNER/bar" rev-parse HEAD)
  before_head=$(git -C "$repo" rev-parse HEAD)
  before_indexes=$(git -C "$repo" hash-object .git/index .git/worktrees/linked/index)
  status=0
  failure=$outcome
  [[ $outcome != success ]] || failure=
  (cd "$linked" && PATH="$TMP/bin:$PATH" HISTORY_LOG_FAILURE=$failure \
    git-subrepo log shared --fetch --group-equivalent --oneline) > "$TMP/fetched" 2>&1 || status=$?
  expected=0
  [[ $outcome != fail ]] || expected=1
  [[ $outcome != term ]] || expected=143
  is "$status" "$expected" "fetching grouped log propagates $outcome"
  is "$(git -C "$repo" rev-parse refs/subrepo/shared/fetch)" "$incoming" \
    "$outcome keeps the newly fetched permanent ref"
  is "$(git -C "$repo" cat-file -p "$incoming:incoming")" "$outcome" \
    "$outcome keeps newly fetched objects readable after scratch cleanup"
  is "$(git -C "$repo" rev-parse HEAD)" "$before_head" "$outcome preserves parent HEAD"
  is "$(git -C "$repo" hash-object .git/index .git/worktrees/linked/index)" "$before_indexes" \
    "$outcome preserves both worktree indexes"
  is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo-operation-lock)" "" \
    "$outcome releases its durable writer lease"
  is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
    "$outcome removes operation scratch and process locks"
  before=$(snapshot)
  (cd "$linked" && git subrepo log shared --incoming --group-equivalent --oneline) > "$TMP/incoming"
  like "$(cat "$TMP/incoming")" "\\[upstream\\] Incoming $outcome contribution" \
    "$outcome permits cached incoming history browsing after cleanup"
  is "$(snapshot)" "$before" "$outcome incoming browsing preserves exact repository state"
done

done_testing
teardown
