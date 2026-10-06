# shellcheck shell=bash disable=2034,2153,2154
# Command state is dynamically scoped by main() in git-subrepo.

history:preflight-all() {
  local subdir=$1 gitrepo subref
  local subrepo_remote='' subrepo_branch=''
  local subrepo_parent='' subrepo_commit='' subrepo_former='' join_method=''
  local history_mode=legacy history_prefix='' history_state='' history_mapped='' history_rewrite=''
  local history_recorded_remote='' history_recorded_branch=''
  local output='' OK=true CODE=0 FAIL=true OUT=false SAY=false
  gitrepo=$subdir/.gitrepo
  read-gitrepo-file
  if [[ $history_mode == prefixed ]]; then
    encode-subdir
    history:validate-path
    if [[ $command =~ ^(pull|push|branch|commit|retarget)$ ]] &&
       history:needs-repair; then
      error "'$subdir/' needs a separately approved history repair before --all.
Run: git subrepo $command $(printf '%q' "$subdir")
Then retry the --all operation."
    fi
  fi
}

history:lifetime-start() {
  # FD 19 is inherited by Git and its transports/hooks. Unlike a PID check,
  # EOF includes descendants left behind when the operation shell is killed.
  # Publish no gate until both ends are open. A missing EOF receipt (including
  # a killed observer) always fails closed; observer death is not proof of EOF.
  mkfifo "$history_tmp/lifetime"
  exec 19<>"$history_tmp/lifetime"
  (
    trap - EXIT
    trap '' INT TERM HUP
    exec 19>&-
    while IFS= read -r ignored; do :; done
    if [[ -f $history_tmp/release ]]; then
      local history_lease='' history_lock=''
      IFS= read -r history_lease < "$history_tmp/release" || true
      if [[ $history_lease ]]; then history_lock=$history_common/subrepo-operation.lock; fi
      if [[ -d $history_common/subrepo-operation.guard/${history_tmp##*/} ]]; then
        HISTORY_CLEANUP_GATE=$history_common/subrepo-operation.guard
      fi
      history:release-files
    else
      : > "$history_tmp/lifetime-ended"
    fi
  ) < "$history_tmp/lifetime" &
  HISTORY_LIFETIME_PID=$!
  HISTORY_LIFETIME_OPEN=true
}

history:lifetime-ended() {
  [[ -d $1 && ! -L $1 &&
     -f $1/lifetime-ended && ! -L $1/lifetime-ended ]]
}

history:lock-gate() {
  local gate=$history_common/subrepo-operation.guard
  local record pid host user index nonce alive=0
  local entries=()
  if ! mkdir "$gate" 2>/dev/null; then
    [[ -d $gate && ! -L $gate ]] ||
      error "Another shared-repository operation is active or its process lock cannot be inspected. Finish that operation before retrying."
    entries=("$gate"/*)
    [[ ${#entries[@]} == 1 && -d ${entries[0]} && ! -L ${entries[0]} ]] ||
      error "Another shared-repository operation is active. Its process-lock owner could not be read; finish that operation before retrying."
    nonce=${entries[0]##*/}
    [[ $nonce =~ ^subrepo-operation\.[a-zA-Z0-9]{8}$ &&
       -d $history_common/$nonce && ! -L $history_common/$nonce ]] ||
      error "The operation process lock has an invalid temporary-directory record. Its files were not removed."
    record=$history_common/$nonce/lease
    [[ -f $record && ! -L $record ]] ||
      error "The operation process-lock owner could not be read. Its files were not removed."
    if ! { pid=$(git config -f "$record" lock.pid) &&
      host=$(git config -f "$record" lock.host) &&
      user=$(git config -f "$record" lock.user) &&
      index=$(git config -f "$record" lock.index) &&
      [[ $(git config -f "$record" lock.nonce) == "$history_common/$nonce" ]]; }; then
      error "The operation process lock has an invalid owner record. Its files were not removed."
    fi
    [[ $pid =~ ^[1-9][0-9]*$ && $host == "$(hostname)" && $user == "$(id -u)" && $index == /* ]] ||
      error "Another shared-repository operation is active or has an unknown owner. Finish that operation before retrying."
    ps -p "$pid" -o pid= > /dev/null 2>&1 || alive=$?
    if ! { [[ $alive == 1 && ! -e $index.lock ]] &&
      [[ $(git config -f "$record" lock.lifetime) == fifo-v1 ]] &&
      history:lifetime-ended "$history_common/$nonce"; }; then
      error "Another shared-repository operation is active, still has a Git lock, or its descendant lifetime cannot be verified. Finish that operation before retrying."
    fi
    # Only one reclaimer can remove this nonce. Never remove a successor's lock.
    if ! { rmdir "${entries[0]}" 2>/dev/null && rmdir "$gate" 2>/dev/null &&
      mkdir "$gate" 2>/dev/null; }; then
      error "Another shared-repository operation started first, or its process lock needs inspection. Finish that operation before retrying."
    fi
    guard_previous_tmp=$history_common/$nonce
  fi
  mkdir "$gate/${history_tmp##*/}"
  HISTORY_CLEANUP_GATE=$gate
}

history:lock() {
  [[ $command =~ ^(help|version|upgrade)$ ]] && return 0
  history_common=$(git rev-parse --git-common-dir)
  history_common=$(cd "$history_common" && pwd -P)
  history_tmp=$(mktemp -d "$history_common/subrepo-operation.XXXXXXXX")
  HISTORY_CLEANUP_COMMON=$history_common
  HISTORY_CLEANUP_TMP=$history_tmp
  HISTORY_CLEANUP_LOCK=
  HISTORY_CLEANUP_LEASE=
  HISTORY_CLEANUP_GATE=
  HISTORY_LIFETIME_OPEN=false
  HISTORY_LIFETIME_PID=
  trap 'history:release' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  history:lifetime-start
  local record=$history_tmp/lease index guard_previous_tmp=''
  git config -f "$record" lock.pid "$$"
  git config -f "$record" lock.host "$(hostname)"
  git config -f "$record" lock.user "$(id -u)"
  index=$(git rev-parse --git-path index)
  [[ $index == /* ]] || index=$PWD/$index
  git config -f "$record" lock.index "$index"
  git config -f "$record" lock.owner "Process $$: $command in $PWD"
  git config -f "$record" lock.nonce "$history_tmp"
  git config -f "$record" lock.lifetime fifo-v1
  # Readers hold the same object-free gate for their entire operation. Writers
  # additionally retain the durable Git lease for interrupted-update recovery.
  history:lock-gate
  if $history_dry_run || { [[ $command =~ ^(status|log)$ ]] && ! $fetch_wanted; }; then
    if git rev-parse --verify refs/subrepo-operation-lock > /dev/null 2>&1 ||
       [[ -e $history_common/subrepo-operation.lock ]]; then
      error "A shared-repository update has not finished. Finish or retry that operation before browsing its state; no project files were changed."
    fi
    if [[ $guard_previous_tmp ]]; then rm -rf -- "$guard_previous_tmp"; fi
    return 0
  fi
  local lock=$history_common/subrepo-operation.lock previous lease pid host user index alive=0 owner=''
  local previous_tmp=''
  previous=$(git rev-parse --verify refs/subrepo-operation-lock 2>/dev/null) || previous=
  if [[ $previous ]]; then
    pid=$(git config --blob "$previous" lock.pid)
    host=$(git config --blob "$previous" lock.host)
    user=$(git config --blob "$previous" lock.user)
    index=$(git config --blob "$previous" lock.index)
    owner=$(git config --blob "$previous" lock.owner)
    alive=2
    if [[ $pid =~ ^[1-9][0-9]*$ && $host == "$(hostname)" && $user == "$(id -u)" && $index == /* ]]; then
      alive=0
      ps -p "$pid" -o pid= > /dev/null 2>&1 || alive=$?
    fi
    if [[ $alive != 1 || -e $index.lock ]]; then
      error "Another shared-repository operation is active or still has a Git lock.
$owner
Finish that operation before retrying. No project files have been changed."
    fi
    previous_tmp=$(git config --blob "$previous" lock.nonce) || previous_tmp=
    [[ ${previous_tmp##*/} =~ ^subrepo-operation\.[a-zA-Z0-9]{8}$ &&
       ! -L $previous_tmp &&
       $(cd "${previous_tmp%/*}" 2>/dev/null && pwd -P) == "$history_common" ]] ||
      error "The interrupted operation has an invalid temporary-directory record.
Its files were not removed. Ask the repository maintainer to inspect refs/subrepo-operation-lock before retrying."
    previous_tmp=$history_common/${previous_tmp##*/}
    if ! { [[ $(git config --blob "$previous" lock.lifetime) == fifo-v1 ]] &&
      history:lifetime-ended "$previous_tmp"; }; then
      error "Another shared-repository operation is active or its descendant lifetime cannot be verified. Its files were not removed."
    fi
  elif [[ -d $lock ]]; then
    [[ ! -f $lock/owner ]] || owner=$(cat "$lock/owner")
    error "Another shared-repository operation is active.
${owner:-Its owner could not be read.}
Finish that operation before retrying. No project files have been changed."
  fi
  lease=$(git hash-object -w "$record")
  # Compare-and-swap prevents two processes from reclaiming a dead owner's lock.
  git update-ref refs/subrepo-operation-lock "$lease" "$previous" 2>/dev/null ||
    error "Another shared-repository operation started first. Finish it before retrying; your project files were not changed."
  history_lease=$lease
  history_lock=$lock
  HISTORY_CLEANUP_LEASE=$lease
  HISTORY_CLEANUP_LOCK=$history_lock
  if [[ $previous ]]; then
    rm -rf -- "$previous_tmp"
  fi
  if [[ $guard_previous_tmp && $guard_previous_tmp != "$previous_tmp" ]]; then
    rm -rf -- "$guard_previous_tmp"
  fi
  if [[ $previous && -d $lock ]]; then
    rm -f "$lock/owner"
    rmdir "$lock"
    say "Recovered an interrupted operation lock. Checking the saved update before continuing."
  fi
  mkdir "$lock"
  printf 'Process %s: %s in %s\n' "$$" "$command" "$PWD" > "$lock/owner"
}

history:release() {
  [[ ${HISTORY_LIFETIME_OPEN:-false} == true ]] || return 0
  local temp=${history_tmp:-${HISTORY_CLEANUP_TMP:-}}
  local lease=${history_lease:-${HISTORY_CLEANUP_LEASE:-}}
  # Request cleanup before closing our writer. Only the EOF observer may remove
  # locks: Git children can still be running even on a normal shell exit.
  printf '%s\n' "$lease" > "$temp/release-next"
  mv -- "$temp/release-next" "$temp/release"
  exec 19>&-
  HISTORY_LIFETIME_OPEN=false
  wait "$HISTORY_LIFETIME_PID" ||
    error "The operation lifetime observer failed. Its remaining locks and files were preserved for inspection."
  HISTORY_CLEANUP_COMMON='' HISTORY_CLEANUP_TMP='' HISTORY_CLEANUP_LOCK='' HISTORY_CLEANUP_LEASE=''
  HISTORY_CLEANUP_GATE=''
}

history:release-files() {
  local common=${history_common:-${HISTORY_CLEANUP_COMMON:-}}
  local temp=${history_tmp:-${HISTORY_CLEANUP_TMP:-}}
  local lock=${history_lock:-${HISTORY_CLEANUP_LOCK:-}}
  local lease=${history_lease:-${HISTORY_CLEANUP_LEASE:-}}
  local gate=${HISTORY_CLEANUP_GATE:-}
  if [[ $lease ]]; then
    # Lease deletion can itself invoke Git hooks. Keep the gate until those
    # descendants finish too, even if the original shell dies during cleanup.
    exec 19<>"$temp/lifetime"
    (
      if [[ $(git --git-dir="$common" rev-parse --verify refs/subrepo-operation-lock 2>/dev/null) == "$lease" ]]; then
        if [[ $lock == "$common/subrepo-operation.lock" && -d $lock ]]; then
          rm -f -- "$lock/owner"
          rmdir "$lock"
        fi
        git --git-dir="$common" update-ref -d refs/subrepo-operation-lock "$lease"
      fi
    ) &
    local cleanup_pid=$!
    exec 19>&-
    while IFS= read -r ignored; do :; done
    wait "$cleanup_pid" || return $?
  fi
  if [[ $gate == "$common/subrepo-operation.guard" && -d $gate && ! -L $gate ]]; then
    if ! { rmdir "$gate/${temp##*/}" && rmdir "$gate"; }; then
      error "The operation process lock could not be released. Its remaining files were preserved for inspection."
    fi
  fi
  if [[ $temp == "$common"/subrepo-operation.* && -d $temp ]]; then
    rm -rf -- "$temp"
  fi
  HISTORY_CLEANUP_COMMON='' HISTORY_CLEANUP_TMP='' HISTORY_CLEANUP_LOCK='' HISTORY_CLEANUP_LEASE=''
  HISTORY_CLEANUP_GATE=''
}

history:field() {
  local file=$1 key=$2 value
  value=$(git config --file="$file" --get-all "subrepo-v2.$key") ||
    error "The tracking file for '$subdir/' is missing '$key'. No project files were changed.
Restore the tracking file from a known-good project commit before retrying."
  [[ $value != *$'\n'* ]] ||
    error "The tracking file for '$subdir/' contains conflicting '$key' values. Resolve its merge before retrying."
  printf '%s' "$value"
}

history:check-layout() {
  local keys key
  keys=$(git config --file="$1" --name-only --list) ||
    error "The tracking file for '$subdir/' is not valid Git configuration. Restore a known-good tracking file before retrying."
  while IFS= read -r key; do
    if [[ $key == subrepo-v* && $key != subrepo-v2.* ]]; then
      error "'$subdir/' uses an unsupported tracking layout. Upgrade git-subrepo before changing this shared repository."
    fi
  done <<< "$keys"
}

history:read() {
  local format
  if git config --file="$gitrepo" --get-regexp '^subrepo\.' > /dev/null; then
    error "'$subdir/' contains both old and new tracking settings.
No project files were changed. Restore one complete tracking file before retrying."
  fi
  format=$(history:field "$gitrepo" format)
  history_rewrite=$(history:field "$gitrepo" rewriteFormat)
  [[ $format == 2 && $history_rewrite == 1 ]] ||
    error "'$subdir/' uses a newer history format ($format/$history_rewrite).
Upgrade git-subrepo before changing this shared repository."
  [[ $(history:field "$gitrepo" history) == prefixed ]] ||
    error "The history mode in '$gitrepo' is not supported by this version."
  history_mode=prefixed
  history_prefix=$(history:field "$gitrepo" prefix)
  history_state=$(history:field "$gitrepo" state)
  [[ $history_state == tracking || $history_state == unpublished ]] ||
    error "The tracking state in '$gitrepo' is not supported."
  history_recorded_remote=$(history:field "$gitrepo" remote)
  history_recorded_branch=$(history:field "$gitrepo" branch)
  subrepo_remote=${override_remote:-$history_recorded_remote}
  subrepo_branch=${override_branch:-$history_recorded_branch}
  history:field "$gitrepo" cmdver > /dev/null
  subrepo_parent=$(history:field "$gitrepo" parent)
  join_method=$(history:field "$gitrepo" method)
  [[ $join_method == merge || $join_method == rebase ]] ||
    error "The join method in '$gitrepo' must be merge or rebase."
  subrepo_commit=
  history_mapped=
  if [[ $history_state == tracking ]]; then
    subrepo_commit=$(history:field "$gitrepo" commit)
    history_mapped=$(history:field "$gitrepo" mappedCommit)
    history:valid-oid "$subrepo_commit"
    history:valid-oid "$history_mapped"
  elif git config --file="$gitrepo" --get-regexp '^subrepo-v2\.(commit|mappedcommit)$' > /dev/null; then
    error "The unpublished tracking file '$gitrepo' contains published commit IDs."
  fi
  history:valid-oid "$subrepo_parent"
  history:set-refs
}

history:set-refs() {
  encode-subdir
  refs_subrepo_branch=refs/subrepo/$subref/branch
  refs_subrepo_commit=refs/subrepo/$subref/commit
  refs_subrepo_fetch=refs/subrepo/$subref/fetch
  refs_subrepo_push=refs/subrepo/$subref/push
}

history:valid-oid() {
  local empty length type
  empty=$(git hash-object --stdin < /dev/null)
  length=${#empty}
  [[ $1 =~ ^[0-9a-f]+$ && ${#1} == "$length" ]] ||
    error "The tracking file for '$subdir/' contains an invalid commit ID. No project files were changed."
  if type=$(git cat-file -t "$1" 2>/dev/null); then
    [[ $type == commit ]] ||
      error "The tracking file for '$subdir/' refers to a non-commit object. Restore a known-good tracking file before retrying."
  fi
}

history:validate-path() {
  if [[ $command == push ]] && $force_wanted; then
    error "Force-pushing is not supported for prefixed shared history. Pull and resolve incoming changes before pushing; no changes were sent."
  fi
  [[ $subdir == "$history_prefix" ]] ||
    error "'$subdir/' was originally tracked at '$history_prefix/'.
Moving a shared directory is not supported yet. Move it back before synchronizing; do not edit its tracking path."
  [[ $subdir && $subdir != /* && $subdir != . && $subdir != ./* &&
     $subdir != */./* && $subdir != */. &&
     $subdir != .. && $subdir != ../* &&
     $subdir != */../* && $subdir != */.. && $subdir != *$'\n'* ]] ||
    error "Use a shared directory inside this project, without '.' or '..' path segments or newlines."
  local component current='' remaining=$subdir
  while [[ $remaining ]]; do
    component=${remaining%%/*}
    [[ ${component,,} != .git ]] ||
      error "The Git administration directory cannot be used as a shared directory."
    current=${current:+$current/}$component
    [[ ! -L $current ]] ||
      error "'$current' is a symbolic link. Use a real project directory for shared history; no files were changed."
    if [[ $remaining == */* ]]; then remaining=${remaining#*/}; else remaining=; fi
  done
  local path
  while IFS= read -r -d '' path; do
    [[ $path == "$gitrepo" ]] && continue
    if [[ $path == "$subdir/"* || "$gitrepo" == "${path%/.gitrepo}/"* ]]; then
      error "'$subdir/' overlaps another shared repository at '${path%/.gitrepo}/'.
Nested shared repositories are not supported in prefixed history. No project files were changed."
    fi
  done < <(git ls-files -z -- '**/.gitrepo')
  local owner=$history_common/subrepo-owners/$subref
  if [[ ! $command =~ ^(log|status|fetch)$ && -f $owner &&
        $(cat "$owner") != "$(git rev-parse --show-toplevel)" ]]; then
    error "The shared worktree for '$subdir/' belongs to another project worktree:
$(cat "$owner")
Finish or clean the shared operation there before retrying. Its files were not changed."
  fi
  if [[ $command =~ ^(clone|init|pull|push|commit|migrate|retarget)$ ]] &&
     [[ -n $(git ls-files --others -- ":(literal)$subdir") ]]; then
    error "'$subdir/' contains untracked or ignored files. Preserve or commit them before synchronizing; no project files were changed."
  fi
  local pending=$history_common/subrepo-pending/$subref/push
  if [[ -f $pending && ! $command =~ ^(status|log|fetch)$ ]]; then
    local request
    request=$(git config -f "$pending" push.request)
    [[ $(history:invocation) == "$request" &&
       $(git rev-parse --show-toplevel) == "$(git config -f "$pending" push.worktree)" &&
       $(git symbolic-ref HEAD) == "$(git config -f "$pending" push.projectBranch)" ]] ||
      error "An earlier publication for '$subdir/' needs local completion first.
Return to its original project worktree and branch, then retry: git subrepo $request
No further changes were sent upstream."
  fi
}

history:write() {
  local file=$1 parent=${history_write_parent:-$subrepo_parent}
  local remote=${history_recorded_remote:-$subrepo_remote}
  local branch=${history_recorded_branch:-$subrepo_branch}
  if $update_wanted || [[ $command == retarget ]]; then
    remote=$subrepo_remote
    branch=$subrepo_branch
  fi
  [[ $parent ]] || parent=$original_head_commit
  cat > "$file" <<'EOF'
; Managed by git-subrepo. This format requires a prefixed-history capable client.
; Do not edit commit IDs to repair history. Run your subrepo command for guidance.
EOF
  git config -f "$file" subrepo-v2.format 2
  git config -f "$file" subrepo-v2.history prefixed
  git config -f "$file" subrepo-v2.rewriteFormat 1
  git config -f "$file" subrepo-v2.prefix "$subdir"
  git config -f "$file" subrepo-v2.state "$history_state"
  git config -f "$file" subrepo-v2.remote "$remote"
  git config -f "$file" subrepo-v2.branch "$branch"
  git config -f "$file" subrepo-v2.parent "$parent"
  git config -f "$file" subrepo-v2.method "${join_method:-merge}"
  git config -f "$file" subrepo-v2.cmdver "$VERSION"
  if [[ $history_state == tracking ]]; then
    git config -f "$file" subrepo-v2.commit "$upstream_head_commit"
    git config -f "$file" subrepo-v2.mappedCommit "$history_mapped"
  fi
}

history:header() {
  git cat-file commit "$1" | sed -n "1,/^$/s/^$2 //p"
}

history:path-code() {
  printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'
}

history:tree() {
  # Bash 4 command substitutions otherwise clear errexit in these object helpers.
  set -e
  local commit=$1 path=${2:-$subdir} tree index
  if ! tree=$(git rev-parse "$commit:$path" 2>/dev/null); then
    git mktree < /dev/null
    return
  fi
  [[ $(git cat-file -t "$tree") == tree ]] ||
    error "'$path' is not a directory in commit $commit."
  index=$(mktemp "$history_tmp/index.XXXXXXXX")
  rm -f "$index"
  GIT_INDEX_FILE=$index git read-tree "$tree"
  GIT_INDEX_FILE=$index git update-index --force-remove .gitrepo
  GIT_INDEX_FILE=$index git write-tree
  rm -f "$index"
}

# Messages never enter shell variables: only headers are parsed and rewritten.
history:object() {
  set -e
  local original=$1 tree=$2 provenance=$3
  shift 3
  local raw target
  raw=$(mktemp "$history_tmp/raw.XXXXXXXX")
  target=$(mktemp "$history_tmp/commit.XXXXXXXX")
  git cat-file commit "$original" > "$raw"
  history:write-object "$raw" "$target" "$tree" "$provenance" "$@"
  rm -f "$raw" "$target"
}

history:write-object() {
  set -e
  local raw=$1 target=$2 tree=$3 provenance=$4
  shift 4
  local line skip=false offset=0 parent
  printf 'tree %s\n' "$tree" > "$target"
  for parent in "$@"; do printf 'parent %s\n' "$parent" >> "$target"; done
  local LC_ALL=C
  while IFS= read -r line; do
    offset=$((offset + ${#line} + 1))
    [[ $line ]] || break
    if [[ $line == ' '* ]]; then
      $skip || printf '%s\n' "$line" >> "$target"
      continue
    fi
    skip=false
    if [[ $provenance == git-subrepo-rewrite\ * && $line == git-subrepo-rewrite\ * ]]; then
      error "The upstream contains browsing-only rewritten commits. Use its original shared-history branch."
    fi
    case "$line" in
      tree\ *|parent\ *|gpgsig\ *|gpgsig-sha256\ *|mergetag\ *|git-subrepo-rewrite\ *)
        skip=true ;;
      *) printf '%s\n' "$line" >> "$target" ;;
    esac
  done < "$raw"
  [[ ! $provenance ]] || printf '%s\n' "$provenance" >> "$target"
  printf '\n' >> "$target"
  tail -c "+$((offset + 1))" "$raw" >> "$target"
  git hash-object -t commit -w "$target"
}

history:validate-rewrite() {
  local tip=$1 paths path
  if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
    error "Complete upstream history is needed for '$subdir/'.
Fetch the missing history before importing. No project files were changed."
  fi
  if [[ -n $(git for-each-ref --format='%(refname)' refs/replace) ||
        -s $history_common/info/grafts ]]; then
    error "History replacements are active. Disable them before rewriting shared history."
  fi
  paths=$(git ls-tree -r --name-only "$tip" -- .gitrepo) ||
    error "The upstream history for '$subdir/' could not be read. Fetch its complete history before retrying."
  if [[ $paths == .gitrepo ]]; then
    error "The incoming tip contains root tracking metadata (.gitrepo).
Remove it from the upstream tip before importing. Historical root tracking metadata may remain in earlier commits."
  fi
  # Stream NUL-delimited paths without scratch files, including during previews.
  paths=$(
    set -o pipefail
    git log --no-show-signature --format= --name-only -z --no-renames --diff-filter=A \
      --full-history --root -m "$tip" -- ':(glob)**/.gitrepo' |
      while IFS= read -r -d '' path; do
        if [[ $path == */.gitrepo ]]; then printf 'nested\n'; fi
      done
  ) || error "The upstream history for '$subdir/' could not be read. Fetch its complete history before retrying."
  if [[ $paths ]]; then
    error "The incoming repository contains nested subrepo metadata. Nested prefixed imports are not supported."
  fi
}

history:rewrite() {
  set -e
  local tip=$1 encoded base original mapped tree parent existing originals incremental=false
  local source_tree source_parents records batch_oid batch_type size
  local prefix=$subdir name
  local tree_ids=()
  local raw=$history_tmp/rewrite-raw target=$history_tmp/rewrite-commit
  local updates=$history_tmp/rewrite-refs batch=$history_tmp/rewrite-batch
  history:validate-rewrite "$tip"
  encoded=$(history:path-code "$subdir")
  base=refs/subrepo/$subref/map-1
  declare -A mapping=() cached=() trees=() processed=()
  records=$(git for-each-ref --format='%(refname) %(objectname)' "$base/")
  while read -r original mapped; do
    [[ $original ]] || continue
    cached[${original#"$base/"}]=$mapped
  done <<< "$records"
  if [[ $subrepo_commit && $history_mapped ]] &&
     [[ ${cached[$subrepo_commit]-} == "$history_mapped" ]] &&
     git merge-base --is-ancestor "$subrepo_commit" "$tip"; then
    for original in "${!cached[@]}"; do mapping[$original]=${cached[$original]}; done
    incremental=true
    originals=$(git rev-list "$subrepo_commit")
    while IFS= read -r original; do
      [[ ${mapping[$original]-} ]] || incremental=false
    done <<< "$originals"
  fi
  if ! $incremental && [[ $history_mapped ]] &&
     git cat-file -e "$history_mapped^{commit}" 2>/dev/null; then
    while IFS= read -r mapped; do
      existing=$(history:header "$mapped" git-subrepo-rewrite)
      if [[ $existing == "1 "*" $encoded" ]]; then
        original=${existing#1 }; original=${original% "$encoded"}
        mapping[$original]=$mapped
      fi
    done < <(git rev-list "$history_mapped")
  fi
  if $incremental; then
    originals=$(git log --no-show-signature --format='%H %T %P' --reverse --topo-order --boundary "$tip" "^$subrepo_commit")
    originals="$(git log --no-show-signature -1 --format='%H %T %P' "$subrepo_commit")"$'\n'"$originals"
  else
    originals=$(git log --no-show-signature --format='%H %T %P' --reverse --topo-order "$tip")
  fi
  while read -r original source_tree source_parents; do
    [[ $original && ! ${trees[$source_tree]-} ]] || continue
    tree_ids+=("$source_tree")
    trees[$source_tree]=$source_tree
  done <<< "$originals"
  # Each prefix component needs one batch, regardless of the commit count.
  while [[ $prefix ]]; do
    name=${prefix##*/}
    for source_tree in "${tree_ids[@]}"; do
      printf '040000 tree %s\t%s\0\0' "${trees[$source_tree]}" "$name"
    done > "$history_tmp/rewrite-trees"
    git mktree -z --batch < "$history_tmp/rewrite-trees" > "$history_tmp/rewrite-tree-ids"
    for source_tree in "${tree_ids[@]}"; do
      read -r tree
      trees[$source_tree]=$tree
    done < "$history_tmp/rewrite-tree-ids"
    if [[ $prefix == */* ]]; then prefix=${prefix%/*}; else prefix=; fi
  done
  # A regular file lets head consume exact byte counts without buffering the next object.
  while read -r original source_tree source_parents; do
    [[ ! $original ]] || printf '%s\n' "$original"
  done <<< "$originals" | git cat-file --batch > "$batch"
  : > "$updates"
  while read -r original source_tree source_parents; do
    [[ $original ]] || continue
    read -r batch_oid batch_type size <&3
    [[ $batch_oid == "$original" && $batch_type == commit && $size =~ ^[0-9]+$ ]] ||
      error "The original shared commit $original could not be read. Fetch its history before retrying."
    head -c "$size" <&3 > "$raw"
    read -r existing <&3
    [[ ! ${processed[$original]-} ]] || continue
    processed[$original]=true
    local parents=()
    for parent in $source_parents; do
      [[ ${mapping[$parent]-} ]] ||
        error "Upstream history is incomplete at $parent. Fetch its parents before retrying."
      parents+=("${mapping[$parent]}")
    done
    mapped=${mapping[$original]-${cached[$original]-}}
    tree=${trees[$source_tree]}
    if [[ $mapped ]]; then
      [[ $(history:header "$mapped" git-subrepo-rewrite) == "1 $original $encoded" &&
         $(git rev-parse "$mapped^{tree}") == "$tree" &&
         $(git show -s --format=%P "$mapped") == "${parents[*]}" ]] ||
        error "The saved history mapping for '$subdir/' is inconsistent. No project files were changed."
    else
      mapped=$(history:write-object "$raw" "$target" "$tree" \
        "git-subrepo-rewrite 1 $original $encoded" "${parents[@]}")
    fi
    if [[ ${cached[$original]-} != "$mapped" ]]; then
      printf 'update %s/%s %s\n' "$base" "$original" "$mapped" >> "$updates"
    fi
    mapping[$original]=$mapped
  done 3< "$batch" <<< "$originals"
  git update-ref --stdin < "$updates"
  printf '%s\n' "${mapping[$tip]}"
}

history:check-upstream() {
  git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null ||
    error "The original shared history for '$subdir/' is missing.
Fetch the recorded shared history before synchronizing. Imported history can still be browsed."
  git merge-base --is-ancestor "$subrepo_commit" "$1" ||
    error "The upstream history for '$subdir/' was replaced or the selected branch has different history.
No project files were changed. Automatic upstream-history replacement is not supported; check the remote and branch with your maintainer."
}

history:integrate() {
  local shared_tree=$1 message=$2 mapped=${3:-}
  local index tree blob expected head merge_path mode_path result=0
  expected=$(git rev-parse HEAD)
  index=$(mktemp "$history_tmp/integration.XXXXXXXX"); rm -f "$index"
  GIT_INDEX_FILE=$index git read-tree HEAD
  GIT_INDEX_FILE=$index git ls-files -z -- ":(literal)$subdir" |
    GIT_INDEX_FILE=$index git update-index --force-remove -z --stdin
  GIT_INDEX_FILE=$index git read-tree --prefix="$subdir/" "$shared_tree"
  history:write "$history_tmp/metadata"
  blob=$(git hash-object -w "$history_tmp/metadata")
  GIT_INDEX_FILE=$index git update-index --add --cacheinfo "100644,$blob,$gitrepo"
  tree=$(GIT_INDEX_FILE=$index git write-tree)
  merge_path=$(git rev-parse --git-path MERGE_HEAD)
  mode_path=$(git rev-parse --git-path MERGE_MODE)
  [[ ! -e $merge_path ]] || error "Finish the current project merge before changing '$subdir/'."
  [[ $(git rev-parse HEAD) == "$expected" ]] ||
    error "The project changed while preparing '$subdir/'. Retry from the current branch."
  [[ -z $(git ls-files --others -- ":(literal)$subdir") ]] ||
    error "'$subdir/' contains untracked or ignored files. Preserve them before retrying; no project files were changed."
  if ! git diff --quiet || ! git diff --cached --quiet; then
    error "Local files changed while preparing '$subdir/'. Preserve those changes before retrying."
  fi
  local args=()
  $edit_wanted && args+=(--edit)
  if [[ $commit_msg_file ]]; then
    args+=(--file "$commit_msg_file")
  else
    args+=(-m "$message")
  fi
  local journal prepared=$history_tmp/journal
  journal=$(git rev-parse --git-path subrepo-integration)
  git config -f "$prepared" operation.parent "$expected"
  git config -f "$prepared" operation.branch "$(git symbolic-ref HEAD)"
  git config -f "$prepared" operation.tree "$tree"
  git config -f "$prepared" operation.mapped "$mapped"
  git config -f "$prepared" operation.directory "$subdir"
  git config -f "$prepared" operation.request "$(history:invocation)"
  git config -f "$prepared" operation.phase "${history_phase:-complete}"
  if [[ ${history_phase:-} == retarget-import ]]; then
    git config -f "$prepared" operation.worktreeTip \
      "$(git -C "$history_common/tmp/subrepo/$subref" rev-parse HEAD)"
  fi
  if [[ $commit_msg_file ]]; then
    cp "$commit_msg_file" "$journal.message"
  else
    printf '%s\n' "$message" > "$journal.message"
  fi
  mv "$prepared" "$journal"
  git read-tree --reset -u "$tree"
  if [[ $mapped ]]; then
    printf '%s\n' "$mapped" > "$merge_path"
    printf 'no-ff' > "$mode_path"
  fi
  git commit --quiet "${args[@]}" || result=$?
  if (( result != 0 )); then
    head=$(git rev-parse HEAD)
    if [[ $head == "$expected" && $(git write-tree) == "$tree" ]] &&
       git diff --quiet; then
      git read-tree --reset -u "$expected"
      [[ ! $mapped ]] || rm -f "$merge_path" "$mode_path"
      if [[ -f $history_common/subrepo-pending/$subref/push ]]; then
        error "Shared changes for '$subdir/' were sent upstream, but the local record could not be saved.
Your project files were restored. Fix the commit hook or signing error above, then retry:
git subrepo $(history:invocation)
The retry will complete the record without sending the changes twice."
      fi
      error "Could not record the change for '$subdir/'. Project files were restored.
Check the commit hook or signing error above, then retry the same command."
    fi
    error "Could not record the change for '$subdir/'. Changes made during the commit were kept.
Review 'git status' and preserve that work before retrying."
  fi
  [[ $(git rev-parse 'HEAD^{tree}') == "$tree" &&
     $(git show -s --format=%P HEAD) == "$expected${mapped:+ $mapped}" ]] ||
    error "The recorded shared update differs from the prepared result. Its commit, files and recovery record were kept. Review any commit-hook changes before continuing."
  original_head_commit=$(git rev-parse HEAD)
  subrepo_parent=${history_write_parent:-$subrepo_parent}
  subrepo_commit=$upstream_head_commit
  rm -f "$index"
  # Retarget still owes publication even when this import commit succeeded.
  if [[ ${history_phase:-} != retarget-import ]]; then
    rm -f "$journal" "$journal.message"
  fi
}

history:resume-integration() {
  [[ $command =~ ^(help|version|upgrade)$ ]] && return 0
  local journal expected tree mapped directory request current index merge_path expected_branch
  journal=$(git rev-parse --git-path subrepo-integration)
  [[ -f $journal ]] || return 0
  expected=$(git config -f "$journal" operation.parent)
  expected_branch=$(git config -f "$journal" operation.branch)
  tree=$(git config -f "$journal" operation.tree)
  mapped=$(git config -f "$journal" operation.mapped)
  directory=$(git config -f "$journal" operation.directory)
  request=$(git config -f "$journal" operation.request)
  current=$(git rev-parse HEAD)
  if [[ $command =~ ^(status|log|fetch)$ ]] || $history_dry_run; then
    printf "An interrupted update for '%s/' needs completion.\nRetry: git subrepo %s\n" "$directory" "$request" >&2
    return
  fi
  [[ $request == "$(history:invocation)" ]] ||
    error "An interrupted update for '$directory/' must be completed first.
Your files were kept. Retry: git subrepo $request"
  [[ $(git symbolic-ref HEAD) == "$expected_branch" ]] ||
    error "The interrupted update belongs to branch '${expected_branch#refs/heads/}'.
Your files were kept. Return to that branch before retrying the saved command."
  local subdir=$directory subref history_mode=prefixed pending remote remote_branch remote_tip
  encode-subdir
  pending=$history_common/subrepo-pending/$subref/push
  if [[ -f $pending && $(git config -f "$journal" operation.phase) != retarget-import ]]; then
    remote=$(git config -f "$pending" push.remote)
    remote_branch=$(git config -f "$pending" push.remoteBranch)
    remote_tip=$(git ls-remote "$remote" "refs/heads/$remote_branch") ||
      error "The earlier push cannot be checked while the remote is unavailable. Reconnect and retry; your files and recovery record were kept."
    remote_tip=${remote_tip%%$'\t'*}
    [[ $remote_tip == "$(git config -f "$pending" push.commit)" ]] ||
      error "The shared branch changed after the earlier push. Your files and recovery record were kept; check the upstream with its maintainer before retrying."
  fi
  if [[ $current != "$expected" ]]; then
    if [[ $(git show -s --format=%P HEAD) == "$expected${mapped:+ $mapped}" &&
          $(git rev-parse 'HEAD^{tree}') == "$tree" ]]; then
      history:finish-resumed "$journal" "$directory"
      return
    fi
    error "The project changed after an interrupted shared update. Your files and its recovery record were kept; review the current branch before retrying."
  fi
  index=$(git write-tree)
  git diff --quiet ||
    error "An interrupted shared update has uncommitted edits. Preserve those edits before retrying; no files were changed."
  [[ $index == "$tree" || $index == "$(git rev-parse 'HEAD^{tree}')" ]] ||
    error "The index changed after an interrupted shared update. Preserve those staged changes before retrying."
  [[ -z $(git ls-files --others -- ":(literal)$directory") ]] ||
    error "Preserve untracked or ignored files in '$directory/' before completing the interrupted update."
  merge_path=$(git rev-parse --git-path MERGE_HEAD)
  [[ ! -f $merge_path || $(cat "$merge_path") == "$mapped" ]] ||
    error "A different project merge is in progress. Finish it before retrying the shared update."
  git cat-file -e "$tree^{tree}" ||
    error "The prepared shared update is missing. Your current files were kept."
  git read-tree --reset -u "$tree"
  if [[ $mapped ]]; then
    git cat-file -e "$mapped^{commit}" ||
      error "The prepared imported history is missing. Your files were kept."
    printf '%s\n' "$mapped" > "$merge_path"
    printf 'no-ff' > "$(git rev-parse --git-path MERGE_MODE)"
  fi
  git commit --quiet --file "$journal.message" ||
    error "The interrupted update is still waiting for a successful commit. Fix the hook or signing error, then retry the same command."
  [[ $(git rev-parse 'HEAD^{tree}') == "$tree" &&
     $(git show -s --format=%P HEAD) == "$expected${mapped:+ $mapped}" ]] ||
    error "The resumed update differs from the prepared result. Its commit, files and recovery record were kept; review any commit-hook changes before continuing."
  history:finish-resumed "$journal" "$directory"
  say "Completed the interrupted update for '$directory/'."
}

history:finish-resumed() {
  local journal=$1 subdir=$2 subref phase pending published
  local history_mode=prefixed
  phase=$(git config -f "$journal" operation.phase)
  encode-subdir
  if [[ $phase == retarget-import ]]; then
    local path=$history_common/tmp/subrepo/$subref tip
    if [[ -d $path ]]; then
      tip=$(git config -f "$journal" operation.worktreeTip) || tip=
      if [[ $tip ]]; then
        [[ $(git -C "$path" rev-parse HEAD) == "$tip" ]] ||
          error "The shared worktree changed after the interrupted import. Its commits and recovery record were kept; preserve that work before retrying."
      else
        [[ $(git -C "$path" rev-parse 'HEAD^{tree}') == "$(history:tree HEAD)" ]] ||
          error "The shared worktree differs from the interrupted import. Its files and recovery record were kept; preserve that work before retrying."
      fi
    fi
    history:remove-worktree
    history_retarget_ready=$subdir
    if $all_wanted; then
      history_resume_after=$subdir
      history_resume_current=true
    fi
    return
  fi
  if [[ $phase != repair ]]; then
    history:remove-worktree
    pending=$history_common/subrepo-pending/$subref/push
    if [[ -f $pending ]]; then
      published=$(git config -f "$pending" push.commit)
      [[ $(git config -f "$subdir/.gitrepo" subrepo-v2.commit) == "$published" ]] ||
        error "The resumed update and pending push disagree. Your files and recovery records were kept."
      git update-ref "refs/subrepo/$subref/push" "$published"
      git update-ref "refs/subrepo/$subref/fetch" "$published"
      rm -f "$pending"
      say "Shared changes were already sent upstream. Completed the local record."
    fi
  fi
  if $all_wanted && [[ $phase != repair ]]; then
    history_resume_after=$subdir
  elif [[ $phase == complete ]]; then
    history_finished_request=true
  fi
  rm -f "$journal" "$journal.message"
}

history:commit() {
  git cat-file -e "$subrepo_commit_ref^{commit}" 2>/dev/null ||
    error "The shared branch '$subrepo_commit_ref' is missing. Run 'git subrepo branch $subdir -F' first."
  git merge-base --is-ancestor "$upstream_head_commit" "$subrepo_commit_ref" ||
    error "The shared branch does not contain the fetched upstream changes. Merge them in its worktree before committing."
  history_state=tracking
  history_mapped=$(history:rewrite "$upstream_head_commit")
  local snapshot message history_write_parent=$subrepo_parent
  snapshot=$(git rev-parse "$subrepo_commit_ref^{tree}")
  if [[ $snapshot == "$(git rev-parse "$upstream_head_commit^{tree}")" || ! $history_write_parent ]]; then
    history_write_parent=$(git rev-parse HEAD)
  fi
  message=${wanted_commit_message:-$(get-commit-message)}
  history:integrate "$snapshot" "$message" "$history_mapped"
  history:remove-worktree
  git:make-ref "$refs_subrepo_commit" "$subrepo_commit_ref"
}

history:init() {
  assert-subdir-ready-for-init
  history_state=unpublished
  subrepo_parent=$(git rev-parse HEAD)
  local snapshot
  snapshot=$(history:tree HEAD)
  history:integrate "$snapshot" "Track shared directory '$subdir' with prefixed history"
}

history:historical-base() {
  set -e
  local commit=$1 file=$history_tmp/historical-metadata
  git cat-file -e "$commit:$gitrepo" 2>/dev/null || return 0
  git cat-file blob "$commit:$gitrepo" > "$file" ||
    error "The historical tracking file for '$subdir/' is not readable in $commit."
  history:check-layout "$file"
  if git config -f "$file" --get-regexp '^subrepo-v2\.' > /dev/null; then
    local gitrepo=$file subrepo_remote subrepo_branch subrepo_parent subrepo_commit join_method
    local history_mode history_prefix history_state history_mapped history_rewrite
    history:read
    [[ $history_prefix == "$subdir" ]] ||
      error "The historical shared path differs in $commit. Moving prefixed shared directories is not supported."
    printf '%s\n' "$subrepo_commit"
  else
    git config -f "$file" subrepo.commit ||
      error "The historical tracking file for '$subdir/' has no shared commit in $commit."
  fi
}

history:export() {
  set -e
  local commits source parent base tree candidate first raw_source encoded
  encoded=$(history:path-code "$subdir")
  declare -A projected=()
  if [[ $history_state == unpublished ]]; then
    commits=$(git rev-list --reverse --topo-order HEAD)
  else
    commits=$(git rev-list --reverse --topo-order --ancestry-path "$subrepo_parent..HEAD")
  fi
  candidate=
  while IFS= read -r source; do
    [[ $source ]] || continue
    [[ ! $(history:header "$source" git-subrepo-rewrite) ]] || continue
    tree=$(history:tree "$source")
    base=$(history:historical-base "$source")
    [[ $base != none ]] || base=
    local parents=() seen
    for parent in $(git show -s --format=%P "$source"); do
      parent=${projected[$parent]-}
      [[ $parent ]] || continue
      seen=" ${parents[*]} "
      [[ $seen == *" $parent "* ]] || parents+=("$parent")
    done
    if [[ $base ]]; then
      git cat-file -e "$base^{commit}" 2>/dev/null ||
        error "An original shared commit needed to export '$subdir/' is missing: $base. Fetch its history before retrying."
      seen=" ${parents[*]} "
      if [[ $seen != *" $base "* ]]; then
        if [[ ${#parents[@]} == 0 ]] ||
           ! git merge-base --is-ancestor "$base" "${parents[0]}"; then
          parents+=("$base")
        fi
      fi
    fi
    candidate=
    for first in "${parents[@]}"; do
      [[ $(git rev-parse "$first^{tree}") == "$tree" ]] || continue
      local contains=true
      for parent in "${parents[@]}"; do
        git merge-base --is-ancestor "$parent" "$first" || contains=false
      done
      if $contains; then candidate=$first; break; fi
    done
    if [[ ! $candidate ]]; then
      if [[ ${#parents[@]} == 0 && $tree == "$(git mktree < /dev/null)" ]]; then
        continue
      fi
      raw_source="git-subrepo-source 1 $source $encoded"
      candidate=$(history:object "$source" "$tree" "$raw_source" "${parents[@]}")
    fi
    projected[$source]=$candidate
  done <<< "$commits"
  candidate=${projected[$(git rev-parse HEAD)]-${subrepo_commit:-}}
  [[ $candidate ]] || error "There are no shared files to publish from '$subdir/'."
  [[ $(git rev-parse "$candidate^{tree}") == "$(history:tree HEAD)" ]] ||
    error "The prepared shared branch does not match '$subdir/'. Nothing was pushed; keep your files and report this history case."
  if [[ $history_state == tracking ]]; then
    git merge-base --is-ancestor "$subrepo_commit" "$candidate" ||
      error "The prepared shared branch lost its upstream history. Nothing was pushed."
  fi
  printf '%s\n' "$candidate"
}

history:branch() {
  local branch=${1:-subrepo/$subref} candidate
  candidate=$(history:export)
  git branch "$branch" "$candidate"
  git:create-worktree "$branch"
  mkdir -p "$(dirname "$history_common/subrepo-owners/$subref")"
  printf '%s\n' "$(git rev-parse --show-toplevel)" > "$history_common/subrepo-owners/$subref"
  git:make-ref "$refs_subrepo_branch" "$branch"
}

history:remove-worktree() {
  local branch=subrepo/$subref path
  path=$history_common/tmp/$branch
  if [[ ! -d $path ]]; then
    rm -f "$history_common/subrepo-owners/$subref"
    return 0
  fi
  if [[ -n $(git -C "$path" status --porcelain) ||
        -n $(git -C "$path" ls-files --others) ]]; then
    error "The shared worktree '$path' contains unfinished changes.
Preserve or commit them there before cleanup. No worktree was deleted."
  fi
  git worktree remove "$path"
  rm -f "$history_common/subrepo-owners/$subref"
}

history:needs-repair() {
  git merge-base --is-ancestor "$subrepo_parent" HEAD 2>/dev/null || return 0
  [[ $history_state == tracking ]] || return 1
  git cat-file -e "$history_mapped^{commit}" 2>/dev/null || return 0
  [[ $(history:header "$history_mapped" git-subrepo-rewrite) == \
     "1 $subrepo_commit $(history:path-code "$subdir")" ]] || return 0
  git merge-base --is-ancestor "$history_mapped" HEAD || return 0
  return 1
}

history:ensure-healthy() {
  history:needs-repair || return 0
  [[ $history_state == tracking ]] ||
    error "The unpublished history link for '$subdir/' is missing.
Keep your files and restore the initialization commit before publishing."
  subrepo:fetch
  local mapped snapshot token expected expected_upstream residual=false
  expected=$(git rev-parse HEAD)
  expected_upstream=$upstream_head_commit
  mapped=$(history:rewrite "$subrepo_commit")
  snapshot=$(history:tree HEAD)
  [[ $snapshot == "$(git rev-parse "$subrepo_commit^{tree}")" ]] || residual=true
  token=$(
    printf '%s\n' "$(history:invocation)" "$expected" "$original_head_branch" "$PWD" "$subdir" \
      "$(git hash-object "$gitrepo")" "$subrepo_commit" "$mapped" \
      "$upstream_head_commit" "$snapshot" | git hash-object --stdin
  )
  printf "The history link for '%s/' needs repair.\n" "$subdir" >&2
  printf '%s\n' \
    "This can happen after a branch is squash-merged, rebased, or cherry-picked." \
    "" \
    "The repair will add one commit and restore the imported history." \
    "Your shared content and other project files will stay the same." \
    "Only subrepo tracking metadata will be updated." >&2
  if $residual; then
    printf '%s\n' "Local shared changes that cannot be separated will be kept as one change." >&2
  fi
  printf "After repair, the requested %s will continue.\n" "$command" >&2
  [[ $command != push && $command != retarget ]] ||
    printf '%s\n' "That operation will send your shared changes upstream." >&2
  local answer=
  if [[ $history_accept ]]; then
    [[ $history_accept == "$token" ]] ||
      error "That approval is for a different project state. Review the new repair and rerun without the old approval."
  elif interactive; then
    read -r -p "Create the repair commit and continue? [y/N] " answer || answer=
    [[ $answer == y || $answer == Y || $answer == yes ]] ||
      error "Stopped without creating a repair commit. Your project files are unchanged; upstream objects were fetched."
  else
    printf '\nNo repair was made. Upstream objects were fetched, but project files are unchanged.\n' >&2
    printf 'To approve this repair, run:\n  git subrepo --accept-repair=%q %s\n' \
      "$token" "$(history:invocation)" >&2
    exit 1
  fi
  [[ $(git rev-parse HEAD) == "$expected" &&
     $(git symbolic-ref --short HEAD) == "$original_head_branch" ]] ||
    error "The project changed after the repair was proposed. Run the command again to review the new repair."
  subrepo:fetch
  [[ $upstream_head_commit == "$expected_upstream" ]] ||
    error "The upstream changed after the repair was proposed. Run the command again to review the new repair."
  local history_write_parent=$expected commit_msg_file='' edit_wanted=false history_phase=repair
  upstream_head_commit=$subrepo_commit
  history_mapped=$mapped
  history:integrate "$snapshot" "Repair shared history for '$subdir' (local changes preserved)" "$mapped"
  say "Repaired history for '$subdir/'. Continuing the requested $command."
}

history:invocation() {
  local arg skip=false
  for arg in "${history_invocation[@]}"; do
    if $skip; then skip=false; continue; fi
    case "$arg" in
      --accept-repair) skip=true ;;
      --accept-repair=*) ;;
      *) printf '%q ' "$arg" ;;
    esac
  done
}

history:push() {
  ! $force_wanted ||
    error "Force-pushing is not supported for prefixed shared history. Pull and resolve incoming changes before pushing; no changes were sent."
  local pending=$history_common/subrepo-pending/$subref/push
  local candidate remote_tip snapshot expected publish=true previous_tip prepared
  snapshot=$(history:tree HEAD)
  remote_tip=$(git ls-remote "$subrepo_remote" "refs/heads/$subrepo_branch") ||
    error "Could not contact the shared repository for '$subdir/'. Check the remote and your connection; nothing was pushed."
  remote_tip=${remote_tip%%$'\t'*}
  if [[ $remote_tip ]]; then
    subrepo:fetch
  elif [[ $history_state != unpublished && $command != retarget ]]; then
    error "The shared branch '$subrepo_branch' is missing upstream. Nothing was pushed; check the selected branch."
  fi
  if [[ -f $pending ]]; then
    candidate=$(git config -f "$pending" push.commit)
    expected=$(git config -f "$pending" push.parent)
    [[ $(git rev-parse HEAD) == "$expected" ]] ||
      error "A previous push for '$subdir/' needs local completion, but the project has changed.
Your files were kept. Return to the recorded project state before retrying."
    if [[ $remote_tip == "$candidate" ]]; then
      publish=false
      say "The shared changes were already sent upstream. Completing the local record."
    elif [[ $remote_tip != "$(git config -f "$pending" push.previous)" ]]; then
      error "A previous push could not be confirmed at the shared branch tip. No further changes were pushed; inspect the upstream before retrying."
    fi
  else
    if [[ $history_state == tracking && $remote_tip && $remote_tip != "$subrepo_commit" ]]; then
      error "There are incoming changes for '$subdir/'. Nothing was pushed.
Run: git subrepo pull $(printf '%q' "$subdir")
Then retry your push."
    fi
    if [[ $history_state == tracking && $remote_tip &&
          $snapshot == "$(git rev-parse "$subrepo_commit^{tree}")" ]]; then
      if [[ $command == push ]] && $update_wanted &&
         [[ $subrepo_remote != "$history_recorded_remote" ||
            $subrepo_branch != "$history_recorded_branch" ]]; then
        local history_write_parent
        history_write_parent=$(git rev-parse HEAD)
        history:integrate "$snapshot" \
          "${wanted_commit_message:-"Update shared repository settings for '$subdir'"}"
        OK=false; CODE=-3
        return
      fi
      OK=false; CODE=-2; return
    fi
    if [[ $branch ]]; then
      candidate=$(git rev-parse "$branch^{commit}") ||
        error "The shared branch '$branch' does not exist."
      [[ $(git rev-parse "$candidate^{tree}") == "$snapshot" ]] ||
        error "The shared branch differs from '$subdir/'. Commit it into the project with 'git subrepo commit' before pushing."
      [[ $history_state != tracking ]] ||
        git merge-base --is-ancestor "$subrepo_commit" "$candidate" ||
        error "The selected shared branch does not contain its upstream history. Nothing was pushed."
    else
      candidate=$(history:export)
    fi
    if $squash_wanted; then
      local parents=() provenance range_base='' item
      [[ ! $subrepo_commit ]] || parents+=("$subrepo_commit")
      if [[ $history_state == tracking ]]; then
        while IFS= read -r item; do
          if [[ $(history:tree "$item") == "$(git rev-parse "$subrepo_commit^{tree}")" ]]; then
            range_base=$item
          fi
        done < <(git rev-list --reverse --ancestry-path "$subrepo_parent..HEAD")
      fi
      provenance=
      if [[ $range_base ]]; then
        provenance="git-subrepo-source-range 1 $range_base $(git rev-parse HEAD) $(history:path-code "$subdir")"
      fi
      candidate=$(history:object HEAD "$snapshot" "$provenance" "${parents[@]}")
    fi
    mkdir -p "$(dirname "$pending")"
    prepared=$history_tmp/pending-push
    git config -f "$prepared" push.commit "$candidate"
    git config -f "$prepared" push.parent "$(git rev-parse HEAD)"
    git config -f "$prepared" push.request "$(history:invocation)"
    git config -f "$prepared" push.worktree "$(git rev-parse --show-toplevel)"
    git config -f "$prepared" push.projectBranch "$(git symbolic-ref HEAD)"
    git config -f "$prepared" push.remote "$subrepo_remote"
    git config -f "$prepared" push.remoteBranch "$subrepo_branch"
    git config -f "$prepared" push.previous "$remote_tip"
    mv "$prepared" "$pending"
  fi
  if $publish; then
    previous_tip=$(git config -f "$pending" push.previous)
    if ! git push "$subrepo_remote" "$candidate:refs/heads/$subrepo_branch"; then
      remote_tip=$(git ls-remote "$subrepo_remote" "refs/heads/$subrepo_branch") ||
        error "The push result could not be confirmed. Your files and pending record were kept. Retry this push after reconnecting."
      remote_tip=${remote_tip%%$'\t'*}
      if [[ $remote_tip != "$candidate" ]]; then
        [[ $remote_tip == "$previous_tip" ]] ||
          error "The shared branch changed while the push was running. Your local changes and pending record were kept; check the upstream before retrying."
        rm -f "$pending"
        error "The shared repository did not accept the push. Your local changes are safe. Check the server message above before retrying."
      fi
    fi
  fi
  upstream_head_commit=$candidate
  history_state=tracking
  history_mapped=$(history:rewrite "$candidate")
  local history_write_parent
  history_write_parent=$(git rev-parse HEAD)
  local message=${wanted_commit_message:-"Record published shared changes for '$subdir'"}
  history:integrate "$snapshot" "$message" "$history_mapped"
  git:make-ref "$refs_subrepo_push" "$candidate"
  git:make-ref "$refs_subrepo_fetch" "$candidate"
  rm -f "$pending"
}

history:retarget() {
  local remote_tip branch='' snapshot target=subrepo/$subref
  if [[ -f $history_common/subrepo-pending/$subref/push ]]; then
    history:publish-retarget
    return
  fi
  remote_tip=$(git ls-remote "$subrepo_remote" "refs/heads/$subrepo_branch") ||
    error "Could not contact the shared repository. Check the remote and your connection; nothing was pushed."
  remote_tip=${remote_tip%%$'\t'*}
  if [[ $remote_tip ]]; then
    subrepo:fetch
    remote_tip=$upstream_head_commit
  fi
  if [[ $history_retarget_ready == "$subdir" ]]; then
    history_retarget_ready=
    if [[ ! $remote_tip || $remote_tip == "$subrepo_commit" ]]; then
      history:publish-retarget
      return
    fi
    # New incoming history needs a new import, not a replay of the saved one.
    local journal
    journal=$(git rev-parse --git-path subrepo-integration)
    rm -f "$journal" "$journal.message"
  fi
  worktree=$history_common/tmp/$target
  snapshot=$(history:tree HEAD)
  if [[ -d $worktree ]]; then
    history:refresh-retarget-worktree "$snapshot"
  fi
  if [[ $remote_tip == "$subrepo_commit" &&
        $subrepo_remote == "$history_recorded_remote" &&
        $subrepo_branch == "$history_recorded_branch" &&
        ! -f $history_common/subrepo-pending/$subref/push ]] &&
     git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null &&
     [[ $snapshot == "$(git rev-parse "$subrepo_commit^{tree}")" ]] &&
     { [[ ! -d $worktree ]] || [[ $(git -C "$worktree" rev-parse 'HEAD^{tree}') == "$snapshot" ]]; }; then
    OK=false CODE=-2
    return
  fi
  if [[ ! $remote_tip ]]; then
    if ! git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null; then
      error "Creating the new branch requires the original shared history.
Fetch the previously tracked branch before retrying; nothing was pushed."
    fi
    if [[ -d $worktree ]]; then
      upstream_head_commit=$subrepo_commit
      subrepo_commit_ref=$target
      local history_phase=retarget-import
      history:commit
      history_phase=complete
    fi
    history:publish-retarget
    return
  fi
  if [[ ! -d $worktree ]]; then
    git:delete-branch "$target"
    history:branch "$target"
  fi
  if [[ $join_method == rebase ]]; then
    git -C "$worktree" rebase "$upstream_head_commit" || { history:conflict; return 1; }
  else
    git -C "$worktree" merge --no-edit "$upstream_head_commit" || { history:conflict; return 1; }
  fi
  subrepo_commit_ref=$target
  local history_phase=retarget-import
  history:commit
  history_phase=complete
  history:publish-retarget
}

history:publish-retarget() {
  history:push
  # A no-op push creates no integration of its own to clear the import journal.
  local journal
  journal=$(git rev-parse --git-path subrepo-integration)
  rm -f "$journal" "$journal.message"
  OK=true
}

history:preview-retarget() {
  local tip path=$history_common/tmp/subrepo/$subref
  printf "Preview retarget of '%s/':\n  From: %s (%s)\n  To:   %s (%s)\n" \
    "$subdir" "$history_recorded_remote" "$history_recorded_branch" "$subrepo_remote" "$subrepo_branch"
  tip=$(git ls-remote "$subrepo_remote" "refs/heads/$subrepo_branch") ||
    error "Could not check the destination. No files, refs, or tracking settings were changed."
  tip=${tip%%$'\t'*}
  if [[ ! $tip ]]; then
    printf '  Destination branch does not exist; retarget will create it and publish shared history.\n'
  elif git cat-file -e "$tip^{commit}" 2>/dev/null &&
       git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null; then
    history:check-upstream "$tip"
    printf '  Incoming commits: %s\n' "$(git rev-list --count "$subrepo_commit..$tip")"
    printf '  Destination file differences from this project (before merging):\n'
    git diff --stat "$tip" "HEAD:$subdir" -- . ':(exclude).gitrepo'
  else
    printf '  Destination tip: %s (not available locally; incoming changes not yet compared).\n' "$tip"
    printf '  To inspect incoming history, fetch the destination explicitly:\n    git subrepo fetch %q --remote %q --branch %q\n' \
      "$subdir" "$subrepo_remote" "$subrepo_branch"
  fi
  if [[ $subrepo_commit ]] && git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null; then
    printf '  Committed project-side shared changes since the recorded upstream:\n'
    git diff --stat "$subrepo_commit" "HEAD:$subdir" -- . ':(exclude).gitrepo'
  else
    printf '  Original shared history is unavailable locally; local changes cannot yet be compared.\n'
  fi
  if [[ -d $path ]]; then
    printf '  Existing shared worktree: %s\n' "$path"
    printf '  Uncommitted work there (empty output means clean):\n'
    git -C "$path" status --short
    printf '  Worktree/project file differences:\n'
    git diff --stat "$(git -C "$path" rev-parse HEAD)" "HEAD:$subdir" -- . ':(exclude).gitrepo'
  fi
  printf '%s\n' \
    'Retarget may merge shared files, create project commits, and publish to the destination.' \
    'This preview does not simulate merges or guarantee a conflict-free result.' \
    'Project-only files are never published there. The project branch needs its own git push.' \
    'Preview only: the remote was checked, but no objects were fetched, refs changed, commits created, or files published.'
}

history:refresh-retarget-worktree() {
  local snapshot=$1 baseline candidate current
  if [[ -n $(git -C "$worktree" status --porcelain) ||
        -n $(git -C "$worktree" ls-files --others) ||
        -f $(git -C "$worktree" rev-parse --git-path MERGE_HEAD) ||
        -d $(git -C "$worktree" rev-parse --git-path rebase-merge) ||
        -d $(git -C "$worktree" rev-parse --git-path rebase-apply) ]]; then
    error "The shared worktree '$worktree' contains unfinished changes or a merge/rebase.
Finish and commit the work there, then retry the original retarget command.
Your project and shared worktree were kept; nothing was pushed."
  fi
  [[ $(git -C "$worktree" symbolic-ref -q HEAD) == "refs/heads/subrepo/$subref" ]] ||
    error "The shared worktree '$worktree' is on a different branch.
Preserve its work and return it to 'subrepo/$subref' before retrying retarget; nothing was pushed."
  current=$(git -C "$worktree" rev-parse HEAD)
  [[ $(git rev-parse "$current^{tree}") != "$snapshot" ]] || return 0
  baseline=$(git rev-parse --verify "$refs_subrepo_branch^{commit}" 2>/dev/null) || baseline=
  if [[ $baseline ]]; then
    [[ $(git rev-parse "$baseline^{tree}") != "$snapshot" ]] || return 0
    if [[ $current == "$baseline" ]]; then
      candidate=$(history:export)
      git -C "$worktree" merge --ff-only "$candidate" ||
        error "The shared worktree could not be refreshed from the project. Its files were kept; nothing was pushed."
      git:make-ref "$refs_subrepo_branch" "$candidate"
      return
    fi
  fi
  error "Both the project's '$subdir/' and its shared worktree may contain changes:
  Project: $(git rev-parse --show-toplevel)/$subdir
  Shared worktree: $worktree
Nothing was integrated or pushed. Preserve the worktree commits on a separate branch,
then reconcile both copies before retrying. Do not use --force or delete the worktree to bypass this check."
}

history:conflict() {
  local path=$worktree retry
  [[ $path == /* ]] || path=$start_pwd/$path
  printf "Shared changes need attention in: %s\n" "$path" >&2
  git -C "$path" diff --name-only --diff-filter=U >&2
  printf 'Edit the conflicted files there, then run:\n  cd %q\n  git add <resolved-files>\n' "$path" >&2
  if [[ $join_method == rebase ]]; then
    printf '  git rebase --continue\n' >&2
  else
    printf '  git commit\n' >&2
  fi
  printf '  cd %q\n' "$start_pwd" >&2
  if [[ $command == retarget ]]; then
    retry=$(history:invocation)
    printf '  git subrepo %s\n' "${retry% }" >&2
  else
    printf '  git subrepo commit %q\n' "$subdir" >&2
  fi
}

history:config() {
  [[ $config_option =~ ^(remote|branch|method|commit|parent|history|format|rewriteFormat|prefix|mappedCommit|state|cmdver)$ ]] ||
    error "Unknown shared-repository setting '$config_option'."
  if [[ ! $config_value ]]; then
    git config -f "$gitrepo" "subrepo-v2.$config_option"
    return
  fi
  if [[ $config_option == method && $config_value =~ ^(merge|rebase)$ ]]; then
    git config -f "$gitrepo" subrepo-v2.method "$config_value"
    say "Updated the join method for '$subdir/'. Commit the tracking file before synchronizing."
  elif [[ $history_state == unpublished && $config_option =~ ^(remote|branch)$ ]]; then
    git config -f "$gitrepo" "subrepo-v2.$config_option" "$config_value"
    say "Updated '$subdir/'. Commit the tracking file before publishing."
  else
    error "This setting controls shared history and cannot be edited directly.
Use 'git subrepo retarget' to change the upstream, or rerun your sync command for repair guidance."
  fi
}

history:preview-migration() {
  local history_dry_run=true
  command-prepare
  command_arguments=( "$1" )
  command:migrate
}

history:preflight-migrate-all() {
  local subdir preview blocked=false
  for subdir in "${subrepos[@]}"; do
    if preview=$(
      exec 2>&1
      trap - EXIT INT TERM
      history:preview-migration "$subdir"
    ); then
      if $history_dry_run; then printf '%s\n' "$preview"; fi
    else
      printf "Migration check failed for '%s/':\n%s\n" "$subdir" "$preview" >&2
      blocked=true
    fi
  done
  if $blocked; then
    error "Migration checks failed. No subrepos were migrated and no project files were changed.
Synchronize the blocked subrepos, then rerun 'git subrepo migrate --all --dry-run'."
  fi
}

command:migrate() {
  command-setup +subdir
  [[ ${history_option:-prefixed} == prefixed ]] ||
    error "Removing published imported history is not supported. Existing history was not changed."
  if [[ $history_mode == prefixed ]]; then
    history:needs-repair &&
      error "This shared repository is already migrated, but needs history repair. Run 'git subrepo pull $subdir' for guidance."
    say "'$subdir/' already uses prefixed history."
    return
  fi
  git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null ||
    error "The recorded shared history is not available locally.
Run 'git subrepo fetch $(printf '%q' "$subdir")', then preview migration again."
  git diff --quiet "$subrepo_commit" "HEAD:$subdir" -- . ':(exclude).gitrepo' ||
    error "'$subdir/' cannot be migrated: its committed shared content differs from its recorded upstream commit.
This is not an uncommitted working-tree change. The tracking record may be behind changes already upstream.
Complete a subrepo push/pull synchronization before migrating; fetch alone does not synchronize content or tracking metadata.
Run 'git subrepo pull $(printf '%q' "$subdir")' to integrate incoming changes, resolve and commit any conflicts,
then 'git subrepo push $(printf '%q' "$subdir")' to publish remaining shared changes. Pull again if needed to finish synchronization.
No project files were changed."
  history_mode=prefixed
  history_prefix=$subdir
  history:set-refs
  history:validate-path
  say "Migrate '$subdir/' to imported history visible in ordinary Git logs."
  say "Existing project commits and content stay unchanged; tracking metadata will be upgraded."
  printf '%s\n' "Collaborators must use a prefixed-history capable git-subrepo client after this commit." >&2
  if $history_dry_run; then
    history:validate-rewrite "$subrepo_commit"
    say "Preview only: nothing was fetched or changed."
    return
  fi
  history_state=tracking
  upstream_head_commit=$subrepo_commit
  history_mapped=$(history:rewrite "$subrepo_commit")
  local history_write_parent
  history_write_parent=$(git rev-parse HEAD)
  local message=${wanted_commit_message:-"Enable prefixed shared history for '$subdir'"}
  history:integrate "$(history:tree HEAD)" "$message" "$history_mapped"
  say "Migrated '$subdir/'. No changes were pushed to a remote."
}

history:read-objects() {
  local objects
  objects=$(git rev-parse --git-path objects)
  objects=$(cd "$objects" && pwd -P)
  # Rendering and equivalence need real projected objects, but must not publish
  # them. Keep this scope below fetch and let the operation lock own cleanup.
  # C-quote the alternate so colons, quotes and backslashes in paths are safe.
  objects=${objects//\\/\\\\}
  objects=${objects//\"/\\\"}
  objects=${objects//$'\n'/\\n}
  objects=${objects//$'\r'/\\r}
  objects=${objects//$'\t'/\\t}
  local -x GIT_ALTERNATE_OBJECT_DIRECTORIES="\"$objects\"${GIT_ALTERNATE_OBJECT_DIRECTORIES:+:$GIT_ALTERNATE_OBJECT_DIRECTORIES}"
  local -x GIT_OBJECT_DIRECTORY=$history_tmp/read-objects
  mkdir -p "$GIT_OBJECT_DIRECTORY"
  "$@"
}

history:status() {
  history:read-objects history:status-render
}

history:status-render() {
  if $quiet_wanted; then printf '%s\n' "$subdir"; return; fi
  printf "Git subrepo '%s':\n" "$subdir"
  if [[ -f $(git rev-parse --git-path subrepo-integration) ]]; then
    printf '  Interrupted shared update. Follow the retry instructions above.\n'
  elif history:needs-repair; then
    printf "  History repair needed. Run: git subrepo pull %q\n" "$subdir"
  elif [[ $history_state == unpublished ]]; then
    printf '  Not yet published. Configure the upstream and push when ready.\n'
  elif ! git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null; then
    printf "  Imported history is available; synchronization needs a fetch.\n  Run: git subrepo fetch %q\n" "$subdir"
  elif ! git diff --quiet "$subrepo_commit" "HEAD:$subdir" -- . ':(exclude).gitrepo'; then
    if [[ $upstream_head_commit && $subrepo_commit != "$(git rev-parse "$refs_subrepo_fetch")" ]]; then
      printf "  Local and incoming changes. Pull before pushing: git subrepo pull %q\n" "$subdir"
    else
      printf "  Local changes ready to push. Run: git subrepo push %q\n" "$subdir"
    fi
  elif [[ $upstream_head_commit && $subrepo_commit != "$(git rev-parse "$refs_subrepo_fetch")" ]]; then
    printf "  Incoming changes available. Run: git subrepo pull %q\n" "$subdir"
  else
    if $fetch_wanted; then
      printf '  Shared content is up to date.\n'
    else
      printf '  No local changes relative to the last fetched shared history.\n'
    fi
  fi
  if $fetch_wanted; then
    printf '  Remote checked by this command.\n'
  else
    printf '  Remote not checked by this command; incoming information is cached.\n'
    printf '  To check for updates: git subrepo status %q --fetch\n' "$subdir"
  fi
  printf '  Remote: %s\n  Branch: %s\n' "$subrepo_remote" "$subrepo_branch"
  if [[ $history_state == tracking ]] && $verbose_wanted; then
    printf '  Original upstream commit: %s\n  Imported project commit: %s\n' \
      "$subrepo_commit" "$history_mapped"
  fi
  if [[ $history_state == tracking ]] && ! history:needs-repair &&
     git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null &&
     { $status_log_wanted || $status_diff_wanted || $verbose_wanted; }; then
    local candidate commits=()
    candidate=$(history:export)
    if [[ $candidate != "$subrepo_commit" ]]; then
      if $status_log_wanted || $verbose_wanted; then
        mapfile -t commits < <(git rev-list "$subrepo_commit..$candidate")
        status-print-log-lines 'Local commits' "$status_log_limit" "${commits[@]}"
      fi
      if $status_diff_wanted; then
        status-print-diffstat Local "$subrepo_commit" "$candidate"
      fi
    fi
    if [[ $upstream_head_commit && $subrepo_commit != "$(git rev-parse "$refs_subrepo_fetch")" ]]; then
      if $status_log_wanted || $verbose_wanted; then
        mapfile -t commits < <(git rev-list "$subrepo_commit..$refs_subrepo_fetch")
        status-print-log-lines 'Remote commits' "$status_log_limit" "${commits[@]}"
      fi
      if $status_diff_wanted; then
        status-print-diffstat Remote "$subrepo_commit" "$refs_subrepo_fetch"
      fi
    fi
  fi
  printf '\n'
}

history:delta() {
  git diff-tree --no-commit-id --raw -z --no-renames -r "$1" "$2" |
    git hash-object --stdin
}

history:equivalent-source() {
  local imported=$1 record version source prefix extra before after source_before
  record=$(history:header "$imported" git-subrepo-source)
  [[ $record && $record != *$'\n'* ]] || return 1
  read -r version source prefix extra <<< "$record"
  [[ $version == 1 && ! $extra && $prefix == "$(history:path-code "$subdir")" ]] || return 1
  git merge-base --is-ancestor "$source" HEAD 2>/dev/null || return 1
  local original
  original=$(history:header "$imported" git-subrepo-rewrite)
  if [[ $original ]]; then
    after=$(history:tree "$imported")
    if git rev-parse "$imported^" > /dev/null 2>&1; then
      before=$(history:tree "$imported^")
    else
      before=$(git mktree < /dev/null)
    fi
  else
    after=$(git rev-parse "$imported^{tree}")
    before=$(git rev-parse "$imported^1^{tree}" 2>/dev/null) || before=$(git mktree < /dev/null)
  fi
  source_before=$(git rev-parse "$source^1" 2>/dev/null) || source_before=
  if [[ $source_before ]]; then
    source_before=$(history:tree "$source_before")
  else
    source_before=$(git mktree < /dev/null)
  fi
  [[ $(history:delta "$before" "$after") == \
     "$(history:delta "$source_before" "$(history:tree "$source")")" ]] || return 1
  printf '%s\n' "$source"
}

history:equivalent-range() {
  local imported=$1 record version base tip prefix extra before after source parent
  record=$(history:header "$imported" git-subrepo-source-range)
  [[ $record && $record != *$'\n'* ]] || return 1
  read -r version base tip prefix extra <<< "$record"
  [[ $version == 1 && ! $extra && $prefix == "$(history:path-code "$subdir")" ]] || return 1
  git merge-base --is-ancestor "$base" "$tip" 2>/dev/null &&
    git merge-base --is-ancestor "$tip" HEAD 2>/dev/null || return 1
  [[ $(history:header "$imported" git-subrepo-rewrite) ]] || return 1
  before=$(history:tree "$imported^")
  after=$(history:tree "$imported")
  [[ $(history:delta "$before" "$after") == \
     "$(history:delta "$(history:tree "$base")" "$(history:tree "$tip")")" ]] || return 1
  while IFS= read -r source; do
    parent=$(git rev-parse "$source^1")
    [[ $(history:tree "$parent") == "$(history:tree "$source")" ]] ||
      printf '%s\n' "$source"
  done < <(git rev-list --first-parent --reverse "$base..$tip" -- ":(literal)$subdir")
}

command:log() {
  command-setup +subdir
  $fetch_wanted && subrepo:fetch
  local revisions=(HEAD) paths=(-- ":(literal)$subdir") commit label record source subject details
  if $history_incoming; then
    if ! git cat-file -e "$refs_subrepo_fetch^{commit}" 2>/dev/null ||
       ! git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null; then
      error "Incoming history for '$subdir/' is not available. Run: git subrepo log $(printf '%q' "$subdir") --fetch --incoming"
    fi
    git merge-base --is-ancestor "$subrepo_commit" "$refs_subrepo_fetch" ||
      error "Fetched upstream history has diverged. No simple incoming range is available."
    revisions=("$subrepo_commit..$refs_subrepo_fetch")
    paths=()
  fi
  local selection=() custom=() arg count pending_count=false
  for arg in "${history_log_args[@]}"; do
    if $pending_count; then
      [[ $arg =~ ^[0-9]+$ ]] || error "'$arg' is not a nonnegative history count."
      selection+=("--max-count=$arg")
      pending_count=false
      continue
    fi
    case "$arg" in
      --oneline) history_oneline=true ;;
      -n|--max-count) pending_count=true ;;
      --max-count=*|-n[0-9]*|-[0-9]*)
        count=${arg#--max-count=}; count=${count#-n}; count=${count#-}
        [[ $count =~ ^[0-9]+$ ]] || error "'$arg' is not a nonnegative history count."
        selection+=("--max-count=$count") ;;
      *) custom+=("$arg") ;;
    esac
  done
  ! $pending_count || error "A nonnegative history count is required after -n or --max-count."
  if [[ ${#custom[@]} != 0 ]]; then
    $history_group &&
      error "Grouped history does not support '${custom[0]}'. Use --oneline --group-equivalent -- -5 for bounded labelled history. Remove --group-equivalent to use other Git options."
    local format=()
    $history_oneline && format+=(--oneline)
    git log "${format[@]}" "${history_log_args[@]}" "${revisions[@]}" "${paths[@]}"
    return
  fi
  history:read-objects history:log-render
}

history:log-render() {
  local commits line metadata=$history_tmp/log-metadata
  commits=$(git rev-list --topo-order "${selection[@]}" "${revisions[@]}" "${paths[@]}")
  [[ $commits ]] || return 0
  declare -A groups=() omitted=() selected=() records=() provenance=()
  # Raw log preserves custom headers and indents messages, so message text cannot
  # masquerade as provenance. Two batch reads replace per-entry display processes.
  git log --no-walk=unsorted --stdin --no-show-signature --no-decorate --no-color \
    --format=raw <<< "$commits" > "$metadata"
  while IFS= read -r line; do
    case "$line" in
      commit\ *) commit=${line#commit }; selected[$commit]=true ;;
      git-subrepo-rewrite\ *) records[$commit]=${line#git-subrepo-rewrite } ;;
      git-subrepo-source\ *|git-subrepo-source-range\ *) provenance[$commit]=true ;;
    esac
  done < "$metadata"
  if $history_group; then
    while IFS= read -r commit; do
      [[ $commit ]] || continue
      [[ ${provenance[$commit]-} ]] || continue
      if source=$(history:equivalent-source "$commit"); then
        if [[ $source != "$commit" && ${selected[$source]-} ]]; then
          groups[$source]="${groups[$source]-} $commit"
          omitted[$commit]=true
        fi
      elif source=$(history:equivalent-range "$commit") && [[ $source ]]; then
        local members=() member representative='' complete=true
        while IFS= read -r member; do
          members+=("$member")
          representative=$member
          [[ ${selected[$member]-} ]] || complete=false
        done <<< "$source"
        if $complete; then
          groups[$representative]=" $commit"
          for member in "${members[@]}"; do
            [[ $member == "$representative" ]] && continue
            groups[$representative]+=" $member"
            omitted[$member]=true
          done
          omitted[$commit]=true
        fi
      fi
    done <<< "$commits"
  fi
  git log --no-walk=unsorted --stdin --no-show-signature --no-decorate --no-color -z \
    --format='%H%x00%s%x00  Author: %an <%ae>%n  Date: %aI%n%n%B' <<< "$commits" > "$metadata"
  while IFS= read -r -d '' commit && IFS= read -r -d '' subject && IFS= read -r -d '' details; do
    [[ ! ${omitted[$commit]-} ]] || continue
    label=local
    $history_incoming && label=upstream
    record=${records[$commit]-}
    [[ ! $record ]] || label=imported
    printf '%s [%s] %s\n' "${commit:0:12}" "$label" "$subject"
    if [[ ${groups[$commit]-} ]]; then
      printf '  Same shared change (not the whole project commit): %s%s\n' "$commit" "${groups[$commit]}"
    elif [[ $record ]]; then
      record=${record#1 }; record=${record%% *}
      printf '  Original upstream commit: %s\n' "$record"
    fi
    if ! $history_oneline; then
      printf '%s\n' "$details"
    fi
  done < "$metadata"
}
