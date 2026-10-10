#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar

mkdir "$TMP/helpers"
cat > "$TMP/helpers/git-remote-securitytest" <<'EOF'
#!/usr/bin/env bash
printf 'transport helper executed\n' > "$TMP/transport-executed"
exit 1
EOF
cp "$TMP/helpers/git-remote-securitytest" "$TMP/helpers/record-transport"
chmod +x "$TMP/helpers/git-remote-securitytest" "$TMP/helpers/record-transport"
export PATH="$TMP/helpers:$PATH"
git config --global protocol.ext.allow always
git config --global protocol.securitytest.allow always

for mode in legacy prefixed; do
  for kind in ext helper helper-url rewrite named push-url head preview; do
    [[ $kind != preview || $mode == prefixed ]] || continue
    repo=$OWNER/$mode-$kind
    git clone -q "$UPSTREAM/foo" "$repo"
    (cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared --history="$mode") > /dev/null
    if [[ $mode == legacy ]]; then section=subrepo; else section=subrepo-v2; fi
    remote=$UPSTREAM/bar
    operation=(fetch shared)
    case "$kind" in
      ext) remote=ext::$TMP/helpers/record-transport ;;
      helper) remote=securitytest::$UPSTREAM/bar ;;
      helper-url) remote=securitytest://fixture/repository ;;
      rewrite|head|preview)
        git -C "$repo" config "url.ext::$TMP/helpers/record-transport.insteadOf" "$remote"
        ;;
      named)
        remote=transport-fixture
        git -C "$repo" remote add "$remote" "securitytest::$UPSTREAM/bar"
        ;;
      push-url)
        remote=transport-fixture
        git -C "$repo" remote add "$remote" "$UPSTREAM/bar"
        git -C "$repo" remote set-url --push "$remote" "ext::$TMP/helpers/record-transport"
        printf 'shared contribution\n' > "$repo/shared/transport-change"
        git -C "$repo" add shared/transport-change
        git -C "$repo" commit -qm 'Shared contribution for transport refusal'
        operation=(push shared)
        ;;
    esac
    git config -f "$repo/shared/.gitrepo" "$section.remote" "$remote"
    git -C "$repo" add shared/.gitrepo
    if ! git -C "$repo" diff --cached --quiet; then
      git -C "$repo" commit -qm 'Recorded transport fixture'
    fi
    if [[ $kind == head ]]; then
      operation=(clone "$remote" incoming --history="$mode")
    elif [[ $kind == preview ]]; then
      operation=(retarget shared --dry-run)
    fi
    before=$(git -C "$repo" rev-parse HEAD)
    status=0
    (cd "$repo" && GIT_ALLOW_PROTOCOL=file:ext:securitytest git subrepo "${operation[@]}") \
      > "$TMP/transport-refused" 2>&1 || status=$?
    isnt "$status" 0 "$mode refuses $kind transport despite Git opt-in"
    test-exists "!$TMP/transport-executed"
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'transport refusal preserves project HEAD'
    is "$(git -C "$repo" status --porcelain)" "" 'transport refusal preserves project files'
    rm -f "$TMP/transport-executed"
  done

  repo=$OWNER/$mode-strict
  git clone -q "$UPSTREAM/foo" "$repo"
  (cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared --history="$mode") > /dev/null
  before=$(git -C "$repo" rev-parse HEAD)
  for allowed in https ''; do
    status=0
    (cd "$repo" && GIT_ALLOW_PROTOCOL="$allowed" git subrepo fetch shared) \
      > "$TMP/strict-refused" 2>&1 || status=$?
    isnt "$status" 0 "$mode preserves stricter caller protocol restrictions ('$allowed')"
    like "$(cat "$TMP/strict-refused")" 'not allowed' 'restricted native transport has an explicit diagnostic'
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'stricter policy refusal preserves HEAD'
  done
  status=0
  (cd "$repo" && GIT_ALLOW_PROTOCOL='file' git subrepo fetch shared) \
    > "$TMP/native-fetch" 2>&1 || status=$?
  is "$status" 0 "$mode still accepts permitted native transports"

  for policy in per-protocol global non-user; do
    case "$policy" in
      per-protocol) git -C "$repo" config protocol.file.allow never ;;
      global)
        git -C "$repo" config --unset protocol.file.allow
        git -C "$repo" config protocol.allow never
        ;;
      non-user) git -C "$repo" config protocol.allow user ;;
    esac
    status=0
    (
      cd "$repo"
      unset GIT_ALLOW_PROTOCOL
      GIT_PROTOCOL_FROM_USER=off git subrepo fetch shared
    ) > "$TMP/config-refused" 2>&1 || status=$?
    isnt "$status" 0 "$mode preserves $policy Git protocol restrictions"
    like "$(cat "$TMP/config-refused")" 'not allowed' 'Git protocol restrictions remain explicit'
    is "$(git -C "$repo" rev-parse HEAD)" "$before" 'Git protocol policy refusal preserves HEAD'
  done
  git -C "$repo" config protocol.file.allow always
  status=0
  (
    cd "$repo"
    unset GIT_ALLOW_PROTOCOL
    GIT_PROTOCOL_FROM_USER=off git subrepo fetch shared
  ) > "$TMP/native-config-fetch" 2>&1 || status=$?
  is "$status" 0 "$mode preserves explicit native protocol opt-in"
done

done_testing
teardown
