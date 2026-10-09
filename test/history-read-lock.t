#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
repo=$OWNER/foo
linked=$OWNER/linked
(
  cd "$repo"
  git subrepo clone "$UPSTREAM/bar" bar
  git subrepo clone "$UPSTREAM/bar" legacy --history=legacy
  git worktree add -q -b linked "$linked"
) > /dev/null

real_git=$(command -v git)
export HISTORY_TEST_GIT=$real_git
export HISTORY_TEST_RMDIR
HISTORY_TEST_RMDIR=$(command -v rmdir)
mkdir "$TMP/bin"
mkfifo "$TMP/ready" "$TMP/release"
exec 8<>"$TMP/release"
exec 9<>"$TMP/ready"
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ ${HISTORY_TEST_HOLD:-} == metadata &&
      $1 == config && $2 == --file=bar/.gitrepo && $3 == --name-only ]] ||
   [[ ${HISTORY_TEST_HOLD:-} == migration &&
      $1 == config && $2 == --file=legacy/.gitrepo && $3 == --name-only ]] ||
   [[ ${HISTORY_TEST_HOLD:-} == writer && $1 == fetch ]]; then
  if mkdir "$TMP/barrier-once" 2>/dev/null; then
    printf '%s\n' "$GIT_SUBREPO_RUNNING" >&9
    read -r answer <&8
    case "$answer" in
      fail) exit 1 ;;
      term) kill -TERM "$GIT_SUBREPO_RUNNING"; exit 1 ;;
      kill) kill -KILL "$GIT_SUBREPO_RUNNING"; exit 1 ;;
    esac
  fi
fi
exec "$HISTORY_TEST_GIT" "$@"
EOF
chmod +x "$TMP/bin/git"
cat > "$TMP/bin/rmdir" <<'EOF'
#!/usr/bin/env bash
if [[ ${HISTORY_TEST_HOLD:-} == reclaim &&
      $1 == */subrepo-operation.guard/subrepo-operation.* ]]; then
  printf 'ready\n' >&7
  read -r answer <&6
fi
exec "$HISTORY_TEST_RMDIR" "$@"
EOF
chmod +x "$TMP/bin/rmdir"
export PATH="$TMP/bin:$PATH"

snapshot() {
  (
    cd "$repo"
    git for-each-ref --format='%(refname) %(objectname)'
    git hash-object .git/index .git/worktrees/linked/index
    find .git/objects -type f | LC_ALL=C sort |
      while IFS= read -r file; do
        printf '%s ' "$file"
        git hash-object "$file"
      done
    find . -name .git -prune -o -type f -print | LC_ALL=C sort |
      while IFS= read -r file; do cksum "$file"; done
    cd "$linked"
    find . -name .git -prune -o -type f -print | LC_ALL=C sort |
      while IFS= read -r file; do cksum "$file"; done
  )
}

start-held() {
  local hold=$1
  shift
  (cd "$linked" && HISTORY_TEST_HOLD=$hold git-subrepo "$@") > "$TMP/held" 2>&1 &
  held=$!
  if ! read -r -t 30 -u 9 operation_pid || [[ ! $operation_pid =~ ^[1-9][0-9]*$ ]]; then
    kill "$held" 2>/dev/null || true
    wait "$held" || true
    cat "$TMP/held" >&2
    die 'operation did not reach the deterministic Git barrier'
  fi
}

finish-held() {
  printf '%s\n' "$1" >&8
  held_status=0
  wait "$held" || held_status=$?
  rmdir "$TMP/barrier-once"
}

assert-cleanup() {
  is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
    "$1 removes operation scratch files and process locks"
  is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo-operation-lock)" "" \
    "$1 leaves no durable writer lease"
}

for reader in status log retarget migrate; do
  args=("$reader" bar)
  hold=metadata
  case "$reader" in
    retarget) args+=(--branch target --dry-run) ;;
    migrate) args=(migrate legacy --dry-run); hold=migration ;;
  esac
  # Stale index stat data must not turn an inspection into an index write.
  touch -t 200001010000 "$linked/bar/Bar" "$linked/legacy/Bar"
  before=$(snapshot)
  start-held "$hold" "${args[@]}"
  status=0
  (cd "$repo" && git subrepo fetch bar) > "$TMP/contender" 2>&1 || status=$?
  is "$status" 1 "$reader holds serialization after entering the actual metadata read"
  like "$(cat "$TMP/contender")" 'Another shared-repository operation is active' \
    "$reader gives the competing linked-worktree writer a busy diagnostic"
  status=0
  (cd "$repo" && git subrepo status bar) > "$TMP/contender" 2>&1 || status=$?
  is "$status" 1 "$reader keeps its lock after the refused writer cleans up"
  is "$(snapshot)" "$before" "$reader and refused writer preserve objects, refs, both indexes and project files"
  finish-held continue
  is "$held_status" 0 "$reader completes after its barrier is released"
  is "$(snapshot)" "$before" "$reader remains read-only through completion"
  assert-cleanup "$reader completion"
  (cd "$repo" && git subrepo fetch bar) > /dev/null
done

start-held writer fetch bar
before=$(snapshot)
for reader in status log retarget migrate; do
  args=("$reader" bar)
  case "$reader" in
    retarget) args+=(--branch target --dry-run) ;;
    migrate) args=(migrate legacy --dry-run) ;;
  esac
  status=0
  (cd "$repo" && git subrepo "${args[@]}") > "$TMP/contender" 2>&1 || status=$?
  is "$status" 1 "$reader is refused while another linked worktree is inside a real writer"
  like "$(cat "$TMP/contender")" 'shared-repository operation is active|shared-repository update has not finished' \
    "$reader explains writer-before-reader refusal"
  is "$(snapshot)" "$before" "$reader refusal does not change the paused writer's repository state"
done
finish-held continue
is "$held_status" 0 'the writer completes after refused readers'
assert-cleanup 'writer completion'

for outcome in fail term kill; do
  before=$(snapshot)
  start-held metadata log bar
  finish-held "$outcome"
  expected=1
  [[ $outcome != term ]] || expected=143
  [[ $outcome != kill ]] || expected=137
  is "$held_status" "$expected" "reader $outcome propagates failure instead of success"
  (cd "$repo" && git subrepo status bar) > /dev/null
  is "$(snapshot)" "$before" "reader $outcome and its read-only retry preserve repository data"
  assert-cleanup "reader $outcome retry"
done

before=$(snapshot)
start-held metadata log bar
finish-held kill
is "$held_status" 137 'ownership checks use an actual abandoned reader lock'
entries=("$repo/.git/subrepo-operation.guard"/*)
nonce=${entries[0]##*/}
record=$repo/.git/$nonce/lease
cp "$record" "$TMP/saved-lease"
for invalid in pid host user nonce index-lock; do
  case "$invalid" in
    pid) git config -f "$record" lock.pid "$$" ;;
    host) git config -f "$record" lock.host unknown.invalid ;;
    user) git config -f "$record" lock.user unknown ;;
    nonce) git config -f "$record" lock.nonce "$repo/.git/$nonce/../protected" ;;
    index-lock) echo preserved > "$repo/.git/worktrees/linked/index.lock" ;;
  esac
  status=0
  (cd "$repo" && git subrepo status bar) > "$TMP/unsafe-owner" 2>&1 || status=$?
  is "$status" 1 "$invalid prevents reclaiming an active or unknown reader owner"
  like "$(cat "$TMP/unsafe-owner")" 'operation.*(active|invalid)' \
    "$invalid refusal explains why reclaiming the process lock is unsafe"
  present=0
  [[ -d ${entries[0]} && -f $record ]] || present=1
  is "$present" 0 \
    "$invalid refusal preserves the abandoned owner's gate and temporary record"
  cp "$TMP/saved-lease" "$record"
  if [[ $invalid == index-lock ]]; then
    is "$(cat "$repo/.git/worktrees/linked/index.lock")" preserved \
      'recovery preserves the linked owner index lock'
    rm "$repo/.git/worktrees/linked/index.lock"
  fi
done
(cd "$repo" && git subrepo status bar) > /dev/null
is "$(snapshot)" "$before" 'validated dead-reader recovery does not create Git objects or change repository data'
assert-cleanup 'validated dead-reader recovery'

# Pause a reclaimer after it checked the dead owner but before its atomic
# nonce removal; a second reclaimer acquires the gate and stays inside fetch.
start-held metadata log bar
finish-held kill
mkfifo "$TMP/reclaim-ready" "$TMP/reclaim-release"
exec 6<>"$TMP/reclaim-release"
exec 7<>"$TMP/reclaim-ready"
(cd "$linked" && HISTORY_TEST_HOLD=reclaim git-subrepo status bar) > "$TMP/reclaimer" 2>&1 &
reclaimer=$!
if ! read -r -t 30 -u 7 signal || [[ $signal != ready ]]; then
  kill "$reclaimer" 2>/dev/null || true
  wait "$reclaimer" || true
  cat "$TMP/reclaimer" >&2
  die 'reclaimer did not reach the nonce-removal barrier'
fi
start-held writer fetch bar
before=$(snapshot)
printf 'continue\n' >&6
status=0
wait "$reclaimer" || status=$?
is "$status" 1 'a delayed reclaimer loses instead of removing a live successor gate'
like "$(cat "$TMP/reclaimer")" 'Another shared-repository operation started first' \
  'the losing reclaimer explains the race and asks for a retry'
is "$(snapshot)" "$before" 'losing reclamation preserves the live writer lease and repository data'
status=0
(cd "$repo" && git subrepo status bar) > "$TMP/contender" 2>&1 || status=$?
is "$status" 1 'the successor still excludes readers after the losing reclaimer exits'
finish-held continue
is "$held_status" 0 'the winning reclaimer completes its real fetch'
assert-cleanup 'racing dead-reader reclamation'
exec 6>&-
exec 7>&-

before=$(snapshot)
mkdir "$repo/.git/subrepo-operation.guard"
status=0
(cd "$repo" && git subrepo status bar) > "$TMP/unknown-owner" 2>&1 || status=$?
is "$status" 1 'an incompletely published gate is not assumed to have a dead owner'
like "$(cat "$TMP/unknown-owner")" 'owner could not be read' \
  'unknown-owner refusal explains why automatic recovery is unsafe'
present=0
[[ -d $repo/.git/subrepo-operation.guard ]] || present=1
is "$present" 0 \
  'unknown-owner refusal preserves the process lock for inspection'
is "$(snapshot)" "$before" 'unknown-owner refusal preserves repository data'
rmdir "$repo/.git/subrepo-operation.guard"
assert-cleanup 'unknown-owner refusal'

exec 8>&-
exec 9>&-
done_testing
teardown
