#!/usr/bin/env bash

set -e
source test/setup
use Test::More
clone-foo-and-bar
installed=$TMP/install/libexec/git-core
make --quiet install INSTALL_LIB="$installed" \
  INSTALL_MAN1="$TMP/install/share/man/man1" > /dev/null
test-exists "$installed/git-subrepo" "$installed/git-subrepo.d/history.bash"
(
  cd "$OWNER/foo"
  env -u GIT_SUBREPO_ROOT "$installed/git-subrepo" clone "$UPSTREAM/bar" bar
  echo installed > bar/installed
  git add .
  git commit -qm 'Installed client contribution'
  env -u GIT_SUBREPO_ROOT "$installed/git-subrepo" push bar
) > /dev/null
is "$(git --git-dir="$UPSTREAM/bar" show master:installed)" installed \
  'installed client works without development source paths or GIT_SUBREPO_ROOT'
is "$(git -C "$OWNER/foo" status --porcelain)" "" 'installed-client round trip leaves a clean project'

done_testing
teardown
