#!/usr/bin/env bash
# shellcheck disable=SC2016

set -e
source test/setup
use Test::More

subdir='shared; printf marker > marker; echo $value | cat; `printf tick > tick`'
history_mode=legacy
encode-subdir
start_pwd=$TMP/paste-start
worktree=$TMP/worktrees/$subref
mkdir -p "$start_pwd" "$worktree"
expected_worktree=$(cd "$worktree" && pwd)
commit_msg_file=$TMP/'message; $value `printf tick`'
subrepo_remote='local; $value `printf tick`'
subrepo_branch=master
override_remote=$subrepo_remote
override_branch=master
update_wanted=true
branch=
export CAPTURE=$TMP/arguments
mkdir "$TMP/recording-bin"
cat > "$TMP/recording-bin/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$#" "$@" >> "$CAPTURE"
EOF
chmod +x "$TMP/recording-bin/git"
for command in pull push retarget; do
  for join_method in merge rebase; do
    error-join > "$TMP/instructions"
    sed -En 's/^  [0-9]+\. ((cd|git) .*)$/\1/p' \
      "$TMP/instructions" > "$TMP/paste"
    : > "$CAPTURE"
    status=0
    (cd "$start_pwd" && PATH="$TMP/recording-bin:$PATH" bash "$TMP/paste") \
      > "$TMP/paste-output" 2>&1 || status=$?
    is "$status" 0 "$command/$join_method recovery commands are safe to paste"
    matches=$(grep -Fxc -- "$subdir" "$CAPTURE" || true)
    expected=2
    [[ $command != pull || $join_method != rebase ]] || expected=3
    is "$matches" "$expected" 'the subdir remains one literal argument in every retry and cleanup command'
    matches=$(grep -Fxc -- "$expected_worktree" "$CAPTURE" || true)
    is "$matches" 1 'the first recovery commit executes inside the exact intended worktree'
    if [[ $command == retarget ]]; then
      matches=$(grep -Fxc -- "Retarget $subdir to $subrepo_remote ($subrepo_branch)" "$CAPTURE" || true)
      is "$matches" 1 'the retarget commit message remains one literal argument'
    fi
    test-exists "!$start_pwd/marker" "!$start_pwd/tick" "!$worktree/marker" "!$worktree/tick"
  done
done
if command -v zsh > /dev/null; then
  git init -q "$TMP/completion"
  (
    cd "$TMP/completion"
    for directory in -O path tools 'space name'; do
      mkdir -- "$directory"
      git config -f "$directory/.gitrepo" subrepo.remote none
      git config -f "$directory/.gitrepo" subrepo.branch master
      git config -f "$directory/.gitrepo" subrepo.commit ""
    done
    git add .
    git commit -qm 'Literal completion candidates'
  )
  export COMPLETION_REPO=$TMP/completion COMPLETION_RESULT=$TMP/completion-result
  cat > "$TMP/completion.zsh" <<'EOF'
zmodload zsh/zpty
zmodload zsh/zselect
zpty -b completion zsh -f
fd=$REPLY
trap 'zpty -d completion' EXIT
wait_marker() {
  local received='' chunk started=$SECONDS
  while [[ $received != *$1* ]]; do
    if (( SECONDS - started > 15 )) || ! zselect -r "$fd" -t 500; then
      print -r -- "Completion timeout: $received" >&2
      return 1
    fi
    if zpty -r completion chunk; then received+=$chunk; fi
  done
}
# Wait for the input editor, not just the end of the setup command.
zpty -w completion 'PS1="READY>"; autoload -Uz compinit; compinit -i -D; source "$GIT_SUBREPO_ROOT/share/zsh-completion/_git-subrepo"; cd "$COMPLETION_REPO"; _test_completion() { local original=$PATH; _compadd_subdirs; printf "%s\n" "$original" "$PATH" "$compstate[nmatches]" > "$COMPLETION_RESULT"; printf "%s%s\n" COMPLETION_ DONE; }; zle -C test-completion complete-word _test_completion; bindkey "^I" test-completion; zle-line-init() { printf "%s%s\n" INPUT_ READY; }; zle -N zle-line-init'
wait_marker INPUT_READY || exit 1
zpty -w -n completion $'git subrepo pull \t'
wait_marker COMPLETION_DONE || exit 1
EOF
  status=0
  zsh -f "$TMP/completion.zsh" > "$TMP/completion-output" 2>&1 || status=$?
  if (( status != 0 )); then
    diag "$(cat "$TMP/completion-output")"
  fi
  is "$status" 0 'real zsh completion handles option-shaped candidates'
  if [[ -f $COMPLETION_RESULT ]]; then
    is "$(sed -n '2p' "$COMPLETION_RESULT")" "$(sed -n '1p' "$COMPLETION_RESULT")" \
      'compadd cannot replace the tied path array'
    is "$(sed -n '3p' "$COMPLETION_RESULT")" 4 \
      'option-shaped names and a space-containing name remain literal completion candidates'
  else
    fail 'the zsh completion callback produced its result'
  fi
fi

done_testing
teardown
