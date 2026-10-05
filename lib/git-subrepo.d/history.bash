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

history:lock() {
  [[ $command =~ ^(help|version|upgrade)$ ]] && return 0
  history_common=$(git rev-parse --git-common-dir)
  history_common=$(cd "$history_common" && pwd)
  if $history_dry_run; then
    return 0
  fi
  history_tmp=$(mktemp -d "$history_common/subrepo-operation.XXXXXXXX")
  HISTORY_CLEANUP_COMMON=$history_common
  HISTORY_CLEANUP_TMP=$history_tmp
  HISTORY_CLEANUP_LOCK=
  HISTORY_CLEANUP_LEASE=
  trap 'history:release' EXIT
  if [[ $command =~ ^(status|log)$ ]] && ! $fetch_wanted; then
    if git rev-parse --verify refs/subrepo-operation-lock > /dev/null 2>&1; then
      error "A shared-repository update has not finished. Finish or retry that operation before browsing its state; no project files were changed."
    fi
    return 0
  fi
  local lock=$history_common/subrepo-operation.lock previous lease pid host user index owner=''
  local previous_tmp=''
  previous=$(git rev-parse --verify refs/subrepo-operation-lock 2>/dev/null) || previous=
  if [[ $previous ]]; then
    pid=$(git config --blob "$previous" lock.pid)
    host=$(git config --blob "$previous" lock.host)
    user=$(git config --blob "$previous" lock.user)
    index=$(git config --blob "$previous" lock.index)
    owner=$(git config --blob "$previous" lock.owner)
    if [[ ! $pid =~ ^[0-9]+$ || $host != "$(hostname)" || $user != "$(id -u)" ]] ||
       ps -p "$pid" -o pid= > /dev/null 2>&1 || [[ -e $index.lock ]]; then
      error "Another shared-repository operation is active or still has a Git lock.
$owner
Finish that operation before retrying. No project files have been changed."
    fi
    previous_tmp=$(git config --blob "$previous" lock.nonce) || previous_tmp=
    [[ ${previous_tmp%/*} == "$history_common" &&
       ${previous_tmp##*/} =~ ^subrepo-operation\.[a-zA-Z0-9]{8}$ &&
       ! -L $previous_tmp ]] ||
      error "The interrupted operation has an invalid temporary-directory record.
Its files were not removed. Ask the repository maintainer to inspect refs/subrepo-operation-lock before retrying."
  elif [[ -d $lock ]]; then
    [[ ! -f $lock/owner ]] || owner=$(cat "$lock/owner")
    error "Another shared-repository operation is active.
${owner:-Its owner could not be read.}
Finish that operation before retrying. No project files have been changed."
  fi
  local record=$history_tmp/lease
  git config -f "$record" lock.pid "$$"
  git config -f "$record" lock.host "$(hostname)"
  git config -f "$record" lock.user "$(id -u)"
  index=$(git rev-parse --git-path index)
  [[ $index == /* ]] || index=$PWD/$index
  git config -f "$record" lock.index "$index"
  git config -f "$record" lock.owner "Process $$: $command in $PWD"
  git config -f "$record" lock.nonce "$history_tmp"
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
  if [[ $previous && -d $lock ]]; then
    rm -f "$lock/owner"
    rmdir "$lock"
    say "Recovered an interrupted operation lock. Checking the saved update before continuing."
  fi
  mkdir "$lock"
  printf 'Process %s: %s in %s\n' "$$" "$command" "$PWD" > "$lock/owner"
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

history:release() {
  local common=${history_common:-${HISTORY_CLEANUP_COMMON:-}}
  local temp=${history_tmp:-${HISTORY_CLEANUP_TMP:-}}
  local lock=${history_lock:-${HISTORY_CLEANUP_LOCK:-}}
  local lease=${history_lease:-${HISTORY_CLEANUP_LEASE:-}}
  if [[ $temp == "$common"/subrepo-operation.* && -d $temp ]]; then
    rm -rf -- "$temp"
  fi
  if [[ $lease && $(git --git-dir="$common" rev-parse --verify refs/subrepo-operation-lock 2>/dev/null) == "$lease" ]]; then
    if [[ $lock == "$common/subrepo-operation.lock" && -d $lock ]]; then
      rm -f -- "$lock/owner"
      rmdir "$lock"
    fi
    git --git-dir="$common" update-ref -d refs/subrepo-operation-lock "$lease"
  fi
  HISTORY_CLEANUP_COMMON='' HISTORY_CLEANUP_TMP='' HISTORY_CLEANUP_LOCK='' HISTORY_CLEANUP_LEASE=''
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

history:nest-tree() {
  set -e
  local tree=$1 prefix=$subdir name
  while [[ $prefix ]]; do
    name=${prefix##*/}
    tree=$(printf '040000 tree %s\t%s\0' "$tree" "$name" | git mktree -z)
    if [[ $prefix == */* ]]; then prefix=${prefix%/*}; else prefix=; fi
  done
  printf '%s\n' "$tree"
}

# Messages never enter shell variables: only headers are parsed and rewritten.
history:object() {
  set -e
  local original=$1 tree=$2 provenance=$3
  shift 3
  local raw target line skip=false offset=0 parent
  raw=$(mktemp "$history_tmp/raw.XXXXXXXX")
  target=$(mktemp "$history_tmp/commit.XXXXXXXX")
  git cat-file commit "$original" > "$raw"
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
  rm -f "$raw" "$target"
}

history:rewrite() {
  set -e
  local tip=$1 encoded base original mapped tree parent existing originals incremental=false
  encoded=$(history:path-code "$subdir")
  base=refs/subrepo/$subref/map-1
  declare -A mapping=()
  if [[ $(git rev-parse --is-shallow-repository) == true ]]; then
    error "Complete upstream history is needed for '$subdir/'.
Fetch the missing history before importing. No project files were changed."
  fi
  if [[ -n $(git for-each-ref --format='%(refname)' refs/replace) ||
        -s $history_common/info/grafts ]]; then
    error "History replacements are active. Disable them before rewriting shared history."
  fi
  if [[ $subrepo_commit && $history_mapped ]] &&
     [[ $(git rev-parse --verify "$base/$subrepo_commit" 2>/dev/null) == "$history_mapped" ]] &&
     git merge-base --is-ancestor "$subrepo_commit" "$tip"; then
    while read -r original mapped; do
      mapping[${original#"$base/"}]=$mapped
    done < <(git for-each-ref --format='%(refname) %(objectname)' "$base/")
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
    originals=$(git rev-list --reverse --topo-order --boundary "$tip" "^$subrepo_commit")
    originals="$subrepo_commit"$'\n'"$originals"
  else
    originals=$(git rev-list --reverse --topo-order "$tip")
  fi
  while IFS= read -r original; do
    [[ $original ]] || continue
    original=${original#-}
    local parents=()
    for parent in $(git show -s --format=%P "$original"); do
      [[ ${mapping[$parent]-} ]] ||
        error "Upstream history is incomplete at $parent. Fetch its parents before retrying."
      parents+=("${mapping[$parent]}")
    done
    mapped=${mapping[$original]-}
    if [[ ! $mapped ]]; then
      mapped=$(git rev-parse --verify "$base/$original" 2>/dev/null) || mapped=
    fi
    tree=$(history:nest-tree "$(git rev-parse "$original^{tree}")")
    if [[ $mapped ]]; then
      [[ $(history:header "$mapped" git-subrepo-rewrite) == "1 $original $encoded" &&
         $(git rev-parse "$mapped^{tree}") == "$tree" &&
         $(git show -s --format=%P "$mapped") == "${parents[*]}" ]] ||
        error "The saved history mapping for '$subdir/' is inconsistent. No project files were changed."
    else
      if git ls-tree -r --name-only "$original" | grep -E '(^|/)\.gitrepo$' > /dev/null; then
        error "The incoming repository contains nested subrepo metadata. Nested prefixed imports are not supported."
      fi
      [[ ! $(history:header "$original" git-subrepo-rewrite) ]] ||
        error "The upstream contains browsing-only rewritten commits. Use its original shared-history branch."
      mapped=$(history:object "$original" "$tree" \
        "git-subrepo-rewrite 1 $original $encoded" "${parents[@]}")
    fi
    git update-ref "$base/$original" "$mapped"
    mapping[$original]=$mapped
  done <<< "$originals"
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
  rm -f "$journal" "$journal.message"
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
  if [[ -f $pending ]]; then
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
  if [[ $phase == retarget-import ]]; then
    history_retarget_ready=$subdir
  fi
  if $all_wanted && [[ $phase != repair ]]; then
    history_resume_after=$subdir
    [[ $phase != retarget-import ]] || history_resume_current=true
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
  local remote_tip branch=
  if [[ $history_retarget_ready == "$subdir" ]]; then
    history_retarget_ready=
    history:push
    OK=true
    return
  fi
  remote_tip=$(git ls-remote "$subrepo_remote" "refs/heads/$subrepo_branch") ||
    error "Could not contact the shared repository. Check the remote and your connection; nothing was pushed."
  if [[ ! $remote_tip ]]; then
    if ! git cat-file -e "$subrepo_commit^{commit}" 2>/dev/null; then
      error "Creating the new branch requires the original shared history.
Fetch the previously tracked branch before retrying; nothing was pushed."
    fi
    history:push
    OK=true
    return
  fi
  subrepo:fetch
  local target=subrepo/$subref
  worktree=$history_common/tmp/$target
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
  history:push
  OK=true
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

history:status() {
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
    printf '  Up to date with the last fetched shared history.\n'
  fi
  printf '  Remote: %s\n  Branch: %s\n' "$subrepo_remote" "$subrepo_branch"
  if [[ $history_state == tracking ]]; then
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
  local revisions=(HEAD) paths=(-- ":(literal)$subdir") commit label record source subject
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
  if [[ ${#history_log_args[@]} != 0 ]]; then
    if [[ ${#history_log_args[@]} == 1 && ${history_log_args[0]} == --oneline ]]; then
      history_oneline=true
    else
      $history_group &&
        error "Grouped history supports standard or --oneline output. Remove --group-equivalent to use custom Git formatting."
      git log "${history_log_args[@]}" "${revisions[@]}" "${paths[@]}"
      return
    fi
  fi
  local commits
  commits=$(git rev-list --topo-order "${revisions[@]}" "${paths[@]}")
  declare -A groups=() omitted=()
  if $history_group; then
    while IFS= read -r commit; do
      [[ $commit ]] || continue
      if source=$(history:equivalent-source "$commit"); then
        if [[ $source != "$commit" && $'\n'"$commits"$'\n' == *$'\n'"$source"$'\n'* ]]; then
          groups[$source]="${groups[$source]-} $commit"
          omitted[$commit]=true
        fi
      elif source=$(history:equivalent-range "$commit") && [[ $source ]]; then
        local members=() member representative='' complete=true
        while IFS= read -r member; do
          members+=("$member")
          representative=$member
          [[ $'\n'"$commits"$'\n' == *$'\n'"$member"$'\n'* ]] || complete=false
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
  while IFS= read -r commit; do
    [[ $commit ]] || continue
    [[ ! ${omitted[$commit]-} ]] || continue
    label=local
    $history_incoming && label=upstream
    record=$(history:header "$commit" git-subrepo-rewrite)
    [[ ! $record ]] || label=imported
    subject=$(git show -s --format=%s "$commit")
    printf '%s [%s] %s\n' "${commit:0:12}" "$label" "$subject"
    if [[ ${groups[$commit]-} ]]; then
      printf '  Same shared change (not the whole project commit): %s%s\n' "$commit" "${groups[$commit]}"
    elif [[ $record ]]; then
      record=${record#1 }; record=${record%% *}
      printf '  Original upstream commit: %s\n' "$record"
    fi
    if ! $history_oneline; then
      git show -s --format='  Author: %an <%ae>%n  Date: %aI%n%n%B' "$commit"
    fi
  done <<< "$commits"
}
