#!/usr/bin/env bash

set -e
source test/setup
use Test::More

mkdir "$TMP/hooks"
cat > "$TMP/editor" <<'EOF'
#!/bin/sh
cat "$1" > "$TEST_STATE/editor-input"
echo edited >> "$TEST_STATE/editor-calls"
printf '\nEditor text  \n# editor comment\n' >> "$1"
test "$(cat "$TEST_STATE/failure")" != editor
EOF
cat > "$TMP/hooks/pre-commit" <<'EOF'
#!/bin/sh
test "$(cat "$TEST_STATE/failure")" != pre-commit
EOF
cat > "$TMP/hooks/prepare-commit-msg" <<'EOF'
#!/bin/sh
if test "$(cat "$TEST_STATE/failure")" = prepare-commit-msg; then
  printf '\nPrepare hook text  \n' >> "$1"
  exit 1
fi
EOF
cat > "$TMP/hooks/commit-msg" <<'EOF'
#!/bin/sh
printf '\nCommit hook text  \n' >> "$1"
test "$(cat "$TEST_STATE/failure")" != commit-msg
EOF
cat > "$TMP/signer" <<'EOF'
#!/bin/sh
echo called > "$TEST_STATE/signer-called"
exit 1
EOF
chmod +x "$TMP/editor" "$TMP/signer" "$TMP/hooks/"*
export GIT_EDITOR="$TMP/editor"

attempt() {
  status=0
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" bar "${options[@]}") \
    > "$TMP/attempt" 2>&1 || status=$?
}

same-bytes() {
  local result=0
  cmp "$1" "$2" > /dev/null 2>&1 || result=$?
  is "$result" 0 "$3"
}

for source in file message; do
  repo=$OWNER/redirected-$source
  git clone -q "$UPSTREAM/foo" "$repo"
  printf 'Preserve outside recovery content\n' > "$TMP/protected-initial-message"
  ln -s "$TMP/protected-initial-message" "$repo/.git/subrepo-integration.message"
  before=$(git -C "$repo" rev-parse HEAD)
  printf 'Intended integration message\n' > "$TMP/intended"
  options=(--file "$TMP/intended")
  if [[ $source == message ]]; then options=(--message 'Intended integration message'); fi
  attempt
  is "$status" 1 "$source initial integration refuses a redirected saved-message destination"
  like "$(cat "$TMP/attempt")" 'message must be a regular file' \
    'initial message refusal explains the unsafe destination'
  is "$(cat "$TMP/protected-initial-message")" 'Preserve outside recovery content' \
    'initial integration preserves the external destination bytes'
  is "$(git -C "$repo" rev-parse HEAD)" "$before" 'initial message refusal preserves project HEAD'
  is "$(git -C "$repo" status --porcelain)" "" 'initial message refusal preserves project files and index'
  rm "$repo/.git/subrepo-integration.message"
  attempt
  is "$status" 0 "$source integration still works after removing the unsafe destination"
done

for boundary in commit-msg signing pre-commit prepare-commit-msg editor; do
  repo=$OWNER/edited-$boundary
  git clone -q "$UPSTREAM/foo" "$repo"
  export TEST_STATE="$repo/.git"
  git -C "$repo" config core.hooksPath "$TMP/hooks"
  git -C "$repo" config gpg.program "$TMP/signer"
  before=$(git -C "$repo" rev-parse HEAD)
  printf 'Intended text  \n\n# intended comment\n\n' > "$TMP/intended"
  cp "$TMP/intended" "$TMP/expected"
  options=(--edit --file "$TMP/intended")
  if [[ $boundary == commit-msg ]]; then
    options=(--edit --message $'Intended text  \n\n# intended comment\n\n')
  fi
  printf 'Unrelated previous commit draft\n' > "$TMP/unrelated"
  cp "$TMP/unrelated" "$TEST_STATE/COMMIT_EDITMSG"
  echo "$boundary" > "$TEST_STATE/failure"
  if [[ $boundary == signing ]]; then
    git -C "$repo" config commit.gpgsign true
  fi

  for retry in 1 2; do
    printf 'Preserve external message bytes\n' > "$TMP/protected-message"
    ln -s "$TMP/protected-message" "$TEST_STATE/subrepo-integration.message.new"
    attempt
    is "$status" 1 "$boundary attempt $retry fails at the real Git boundary"
    is "$(cat "$TMP/protected-message")" 'Preserve external message bytes' \
      "$boundary attempt $retry never writes through a predictable message temporary symlink"
    is "$([[ -L $TEST_STATE/subrepo-integration.message.new ]] && echo preserved)" preserved \
      'message saving leaves an unrelated temporary-path symlink untouched'
    rm -f "$TEST_STATE/subrepo-integration.message.new"
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'failure does not create a parent commit'
    if [[ $retry == 1 ]]; then
      is "$(git -C "$repo" status --porcelain)" "" 'first failure safely restores project files'
    fi
    case "$boundary" in
      pre-commit) ;;
      prepare-commit-msg) printf '\nPrepare hook text  \n' >> "$TMP/expected" ;;
      *)
        # Git strips whitespace from its input before opening the editor.
        git stripspace < "$TMP/expected" > "$TMP/cleaned"
        mv "$TMP/cleaned" "$TMP/expected"
        printf '\nEditor text  \n# editor comment\n' >> "$TMP/expected"
        if [[ $boundary != editor ]]; then
          printf '\nCommit hook text  \n' >> "$TMP/expected"
        fi
        ;;
    esac
    if [[ $boundary != pre-commit ]]; then
      # Git also adds its own commented status before invoking the editor.
      # Preserve the exact draft, including that text, across the failure.
      same-bytes "$TEST_STATE/COMMIT_EDITMSG" "$TEST_STATE/subrepo-integration.message" \
        "$boundary attempt $retry journals the actual raw attempted draft"
    else
      same-bytes "$TMP/intended" "$TEST_STATE/subrepo-integration.message" \
        'pre-commit failure does not adopt the unrelated COMMIT_EDITMSG'
      same-bytes "$TMP/unrelated" "$TEST_STATE/COMMIT_EDITMSG" \
        'failure before message preparation keeps the previous unrelated draft'
    fi
  done
  if [[ $boundary == signing ]]; then
    is "$(cat "$TEST_STATE/signer-called")" called 'Git actually invokes the failing signer'
    git -C "$repo" config commit.gpgsign false
  fi
  if [[ $boundary == commit-msg ]]; then
    cp "$TEST_STATE/subrepo-integration.message" "$TMP/saved"
    cp "$TMP/unrelated" "$TEST_STATE/COMMIT_EDITMSG"
    echo pre-commit > "$TEST_STATE/failure"
    attempt
    is "$status" 1 'an early failure can also interrupt a retry after successful edits'
    same-bytes "$TMP/saved" "$TEST_STATE/subrepo-integration.message" \
      'early retry failure keeps the saved edits rather than a stale unrelated draft'
  fi
  echo success > "$TEST_STATE/failure"
  # The original --file is not the durable retry source.
  printf 'Changed external message file\n' > "$TMP/intended"
  attempt
  is "$status" 0 "$boundary exact retry completes the saved integration"
  count=3
  if [[ $boundary == pre-commit || $boundary == prepare-commit-msg ]]; then count=1; fi
  is "$(wc -l < "$TEST_STATE/editor-calls" | tr -d ' ')" "$count" \
    "$boundary retries retain the requested editor"
  printf '\nEditor text  \n# editor comment\n\nCommit hook text  \n' >> "$TMP/expected"
  git stripspace --strip-comments < "$TMP/expected" > "$TMP/final-expected"
  git -C "$repo" cat-file commit HEAD | sed '1,/^$/d' > "$TMP/actual"
  same-bytes "$TMP/final-expected" "$TMP/actual" \
    "$boundary final message retains all attempted user and hook text with Git cleanup"
  is "$(git -C "$repo" rev-parse HEAD^1)" "$before" 'retry records exactly one integration'
  is "$(git -C "$repo" status --porcelain)" "" 'completed retry leaves the project clean'
  test-exists "!$TEST_STATE/subrepo-integration"
done

for source in file message; do
  repo=$OWNER/raw-$source
  git clone -q "$UPSTREAM/foo" "$repo"
  export TEST_STATE="$repo/.git"
  git -C "$repo" config core.hooksPath "$TMP/hooks"
  git -C "$repo" config commit.cleanup verbatim
  printf '\nRaw message  \n# literal comment\n\n\n' > "$TMP/intended"
  options=(--file "$TMP/intended")
  if [[ $source == message ]]; then
    options=(--message $'\nRaw message  \n# literal comment\n\n\n')
  fi
  cp "$TMP/intended" "$TMP/expected"
  echo pre-commit > "$TEST_STATE/failure"
  attempt
  is "$status" 1 "$source verbatim failure before message preparation is recoverable"
  same-bytes "$TMP/expected" "$TEST_STATE/subrepo-integration.message" \
    "$source intended bytes are saved without adding an extra newline"
  echo commit-msg > "$TEST_STATE/failure"
  for retry in 1 2; do
    attempt
    is "$status" 1 "$source verbatim attempt $retry fails in commit-msg"
    printf '\nCommit hook text  \n' >> "$TMP/expected"
    same-bytes "$TMP/expected" "$TEST_STATE/subrepo-integration.message" \
      "$source verbatim draft preserves raw whitespace and repeated hook edits"
  done
  echo success > "$TEST_STATE/failure"
  attempt
  is "$status" 0 "$source verbatim retry succeeds"
  printf '\nCommit hook text  \n' >> "$TMP/expected"
  git -C "$repo" cat-file commit HEAD | sed '1,/^$/d' > "$TMP/actual"
  same-bytes "$TMP/expected" "$TMP/actual" "$source final raw message matches Git verbatim semantics"
  test-exists "!$TEST_STATE/editor-calls"
done

done_testing
teardown
