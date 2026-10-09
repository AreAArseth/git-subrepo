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
  git worktree add -q -b linked "$linked"
) > /dev/null

mkfifo "$TMP/ready" "$TMP/release" "$TMP/finished"
exec 8<>"$TMP/release"
exec 9<>"$TMP/ready"
exec 7<>"$TMP/finished"
cat > "$TMP/server-hook" <<'EOF'
#!/usr/bin/env bash
if [[ ${HISTORY_ORPHAN_HOLD:-} != yes ]]; then
  if [[ $# != 0 ]]; then exec "$@"; fi
  exit 0
fi
printf '%s %s %s\n' "$GIT_SUBREPO_RUNNING" "$BASHPID" "$PPID" >&9
read -r answer <&8
printf 'released\n' >&7
if [[ $# != 0 ]]; then exec "$@"; fi
EOF
chmod +x "$TMP/server-hook"

snapshot() {
  (
    cd "$repo"
    git for-each-ref --format='%(refname) %(objectname)'
    git hash-object .git/index .git/worktrees/linked/index
    find .git/objects -type f -print | LC_ALL=C sort |
      while IFS= read -r file; do cksum "$file"; done
    find .git -name 'subrepo-operation*' -print | LC_ALL=C sort
    find .git/subrepo-operation.* -type f ! -name lifetime-ended -print |
      LC_ALL=C sort | while IFS= read -r file; do cksum "$file"; done
    git status --porcelain
    git -C "$linked" status --porcelain
  )
}

for operation in fetch push; do
  if [[ $operation == fetch ]]; then
    (
      cd "$OWNER/bar"
      echo incoming > incoming
      git add .
      git commit -qm incoming
      git push -q
    )
    git config --global uploadpack.packObjectsHook "$TMP/server-hook"
  else
    git config --global --unset uploadpack.packObjectsHook
    (cd "$linked" && git subrepo pull bar) > /dev/null
    mkdir -p "$UPSTREAM/bar/hooks"
    cp "$TMP/server-hook" "$UPSTREAM/bar/hooks/pre-receive"
    (
      cd "$linked"
      echo outgoing > bar/outgoing
      git add .
      git commit -qm outgoing
    )
  fi
  (cd "$linked" && HISTORY_ORPHAN_HOLD=yes git-subrepo "$operation" bar) > "$TMP/operation" 2>&1 &
  held=$!
  if ! read -r -t 30 -u 9 operation_pid hook_pid server_pid; then
    cat "$TMP/operation" >&2
    kill "$held" 2>/dev/null || true
    wait "$held" || true
    die "$operation did not reach its real Git server hook"
  fi
  status=0
  kill -0 "$hook_pid" 2>/dev/null || status=$?
  is "$status" 0 "$operation server hook is alive at its FIFO barrier"
  is "$(find "$repo/.git" -name index.lock -print)" "" "$operation is paused without an index lock"
  kill -KILL "$operation_pid"
  status=0
  wait "$held" || status=$?
  is "$status" 137 "$operation kills only the identified operation shell"
  status=0
  { kill -0 "$hook_pid" 2>/dev/null && kill -0 "$server_pid" 2>/dev/null; } || status=$?
  is "$status" 0 \
    "$operation leaves its real Git server and hook alive"
  before=$(snapshot)
  status=0
  (cd "$repo" && git subrepo fetch bar) > "$TMP/contender" 2>&1 || status=$?
  is "$status" 1 "$operation orphan excludes a competing linked-worktree writer"
  like "$(cat "$TMP/contender")" 'operation.*active' "$operation retry explains the live operation"
  is "$(snapshot)" "$before" "$operation refused retry preserves locks, lease, scratch state and both indexes"
  printf 'continue\n' >&8
  read -r -t 30 -u 7 answer
  [[ $answer == released ]] || die "$operation server hook did not acknowledge release"
  # Poll only the identified server, never the machine's process table.
  for ((attempt=0; attempt<300; attempt++)); do
    kill -0 "$server_pid" 2>/dev/null || break
    sleep .1
  done
  status=0
  kill -0 "$server_pid" 2>/dev/null || status=$?
  isnt "$status" 0 "$operation orphan terminates after its FIFO release"
  # The EOF observer publishes only after the complete descendant tree exits.
  for ((attempt=0; attempt<300; attempt++)); do
    entries=("$repo/.git"/subrepo-operation.*/lifetime-ended)
    [[ -f ${entries[0]} ]] && break
    sleep .1
  done
  status=0
  [[ -f ${entries[0]} ]] || status=1
  is "$status" 0 "$operation observer records descendant EOF"
  receipt=${entries[0]}
  mv "$receipt" "$TMP/receipt"
  before=$(snapshot)
  status=0
  (cd "$repo" && git subrepo fetch bar) > "$TMP/unverified" 2>&1 || status=$?
  is "$status" 1 "$operation cannot reclaim a dead shell without its descendant EOF receipt"
  is "$(snapshot)" "$before" "$operation missing receipt preserves the abandoned operation"
  nonce=${receipt%/lifetime-ended}
  nonce=${nonce##*/}
  rmdir "$repo/.git/subrepo-operation.guard/$nonce" "$repo/.git/subrepo-operation.guard"
  before=$(snapshot)
  status=0
  (cd "$repo" && git subrepo fetch bar) > "$TMP/unverified-lease" 2>&1 || status=$?
  is "$status" 1 "$operation durable lease also requires EOF when the process gate is missing"
  is "$(snapshot)" "$before" "$operation unverified lease retains its files and refs"
  mkdir -p "$repo/.git/subrepo-operation.guard/$nonce"
  mv "$TMP/receipt" "$receipt"
  if [[ $operation == push ]]; then rm "$UPSTREAM/bar/hooks/pre-receive"; fi
  (cd "$linked" && git subrepo "$operation" bar) > "$TMP/retry" 2>&1
  is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
    "$operation retry succeeds and cleans operation locks after the orphan ends"
  is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo-operation-lock)" "" \
    "$operation retry removes its durable lease"
done

# A server hook may exit normally while its child continues working. Closing
# stdio ensures Git can finish; the lifetime descriptor must still hold cleanup.
cat > "$UPSTREAM/bar/hooks/pre-receive" <<'EOF'
#!/usr/bin/env bash
(
  printf '%s %s %s\n' "$GIT_SUBREPO_RUNNING" "$BASHPID" "$PPID" >&9
  read -r answer <&8
) </dev/null > /dev/null 2>&1 &
exit 0
EOF
chmod +x "$UPSTREAM/bar/hooks/pre-receive"
(
  cd "$repo"
  git subrepo pull bar
  echo descendant > bar/descendant
  git add .
  git commit -qm descendant
) > /dev/null
(cd "$repo" && git-subrepo push bar) > "$TMP/normal-exit" 2>&1 &
held=$!
read -r -t 30 -u 9 operation_pid hook_pid server_pid
for ((attempt=0; attempt<300; attempt++)); do
  releases=("$repo/.git"/subrepo-operation.*/release)
  [[ -f ${releases[0]} ]] && break
  sleep .1
done
status=0
[[ -f ${releases[0]} ]] || status=1
is "$status" 0 'normal operation reaches cleanup while the hook descendant is still alive'
status=0
kill -0 "$hook_pid" 2>/dev/null || status=$?
is "$status" 0 'the hook descendant outlives its completed Git push'
before=$(snapshot)
status=0
(cd "$linked" && git subrepo status bar) > "$TMP/normal-contender" 2>&1 || status=$?
is "$status" 1 'normal-exit cleanup retains serialization until the descendant exits'
is "$(snapshot)" "$before" 'normal-exit refusal preserves operation locks and repository state'
printf 'continue\n' >&8
status=0
wait "$held" || status=$?
is "$status" 0 'normal push succeeds after its last descendant finishes'
is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
  'normal-exit observer cleans the gate, durable lease and scratch files'
rm "$UPSTREAM/bar/hooks/pre-receive"

# Stop immediately after the real lease CAS, before the shell can record its
# successful acquisition. The in-flight publisher must retain lifetime ownership.
mkdir "$TMP/bin"
export HISTORY_ORPHAN_GIT
HISTORY_ORPHAN_GIT=$(command -v git)
cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ ${HISTORY_PUBLISH_HOLD:-} == yes &&
      $1 == update-ref && $2 == refs/subrepo-operation-lock ]]; then
  "$HISTORY_ORPHAN_GIT" "$@" || exit $?
  printf '%s %s\n' "$GIT_SUBREPO_RUNNING" "$BASHPID" >&9
  read -r answer <&8
  exit 0
fi
exec "$HISTORY_ORPHAN_GIT" "$@"
EOF
chmod +x "$TMP/bin/git"
(cd "$linked" && PATH="$TMP/bin:$PATH" HISTORY_PUBLISH_HOLD=yes git-subrepo fetch bar) > "$TMP/publisher" 2>&1 &
held=$!
read -r -t 30 -u 9 operation_pid publisher_pid
kill -KILL "$operation_pid"
status=0
wait "$held" || status=$?
is "$status" 137 'lease publication kills only its identified operation shell'
status=0
kill -0 "$publisher_pid" 2>/dev/null || status=$?
is "$status" 0 'the lease publisher outlives its shell before acquisition is acknowledged'
before=$(snapshot)
status=0
(cd "$repo" && git subrepo fetch bar) > "$TMP/publish-contender" 2>&1 || status=$?
is "$status" 1 'an unacknowledged lease acquisition still excludes a competing writer'
is "$(snapshot)" "$before" 'publication-window refusal preserves the acquired lease and scratch state'
printf 'continue\n' >&8
for ((attempt=0; attempt<300; attempt++)); do
  entries=("$repo/.git"/subrepo-operation.*/lifetime-ended)
  [[ -f ${entries[0]} ]] && break
  sleep .1
done
(cd "$linked" && git subrepo fetch bar) > "$TMP/publish-retry" 2>&1
is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
  'the completed publisher can be recovered without acquisition-acknowledgment state'
is "$(git -C "$repo" for-each-ref --format='%(refname)' refs/subrepo-operation-lock)" "" \
  'publication-window retry removes the durable lease'

# Reference-transaction hooks were introduced after our minimum supported Git.
if [[ $git_major -gt 2 || ( $git_major -eq 2 && $git_minor -ge 29 ) ]]; then
  cat > "$repo/.git/hooks/reference-transaction" <<'EOF'
#!/usr/bin/env bash
[[ $1 == committed ]] || exit 0
while read -r old new ref; do
  if [[ $ref == refs/subrepo-operation-lock && $new =~ ^0+$ ]]; then
    (
      printf '%s %s\n' "$GIT_SUBREPO_RUNNING" "$BASHPID" >&9
      read -r answer <&8
    ) </dev/null > /dev/null 2>&1 &
  fi
done
exit 0
EOF
  chmod +x "$repo/.git/hooks/reference-transaction"
  (cd "$linked" && git-subrepo fetch bar) > "$TMP/cleanup-hook" 2>&1 &
  held=$!
  read -r -t 30 -u 9 operation_pid hook_pid
  kill -KILL "$operation_pid"
  status=0
  wait "$held" || status=$?
  is "$status" 137 'cleanup interruption kills only the original operation shell'
  status=0
  kill -0 "$hook_pid" 2>/dev/null || status=$?
  is "$status" 0 'the actual lease-deletion hook descendant survives its operation shell'
  before=$(snapshot)
  status=0
  (cd "$repo" && git subrepo status bar) > "$TMP/cleanup-contender" 2>&1 || status=$?
  is "$status" 1 'lease-deletion descendants retain the gate even after the durable ref is removed'
  is "$(snapshot)" "$before" 'cleanup-window refusal preserves the observer and its gate'
  printf 'continue\n' >&8
  for ((attempt=0; attempt<300; attempt++)); do
    [[ ! -d $repo/.git/subrepo-operation.guard ]] && break
    sleep .1
  done
  rm "$repo/.git/hooks/reference-transaction"
  (cd "$repo" && git subrepo fetch bar) > "$TMP/cleanup-retry" 2>&1
  is "$(find "$repo/.git" -maxdepth 1 -name 'subrepo-operation*' -print)" "" \
    'cleanup finishes and retry succeeds after its last hook descendant exits'
fi

exec 7>&-
exec 8>&-
exec 9>&-
done_testing
teardown
