#!/usr/bin/env bash
# shellcheck disable=SC2031

set -e
source test/setup
use Test::More

outside=$TMP/user-config
mkdir -p "$outside/git"
printf '[user]\n\tname = Outside User\n[http]\n\tsslVerify = true\n' > "$outside/git/config"
cp "$outside/git/config" "$TMP/original-config"
export OUTSIDE_XDG=$outside CONFIG_RESULT=$TMP/config-result
(
  export XDG_CONFIG_HOME=$OUTSIDE_XDG
  source test/setup
  printf '%s\n' "$XDG_CONFIG_HOME" "$HOME/.config" > "$CONFIG_RESULT"
  git config --global --get http.sslverify > "$CONFIG_RESULT.tls" || true
  teardown
) > "$TMP/setup-log" 2>&1
status=0
cmp "$TMP/original-config" "$outside/git/config" || status=$?
is "$status" 0 'test setup preserves the inherited XDG Git config byte for byte'
is "$(sed -n '1p' "$CONFIG_RESULT")" "$(sed -n '2p' "$CONFIG_RESULT")" \
  'XDG config resolution is confined to the temporary test HOME on older Git too'
is "$(cat "$CONFIG_RESULT.tls")" "" 'tests do not disable TLS certificate verification'

done_testing
teardown
