#!/usr/bin/env bash

set -e

export DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
source test/setup

use Test::More

if ! command -v docker >/dev/null; then
  teardown
  plan skip_all "The 'docker' utility is not installed"
fi
if ! docker info > /dev/null 2>&1; then
  teardown
  plan skip_all 'The Docker daemon is not available'
fi

for zsh_version in 5.8 5.6 5.0.1 4.3.11; do
  image=zshusers/zsh:$zsh_version
  if ! docker image inspect "$image" > /dev/null 2>&1; then
    docker pull "$image" >&2
  fi
  status=0
  error=$(
    docker run --rm \
      --volume="$PWD:/git-subrepo" \
      --entrypoint='' \
        "$image" \
        zsh -c 'source /git-subrepo/.rc' 2>&1
  ) || status=$?

  is "$status" 0 "'source.rc' exits successfully for zsh-$zsh_version"
  is "$error" "" "'source.rc' works for zsh-$zsh_version"
done

done_testing
teardown

# vim: set ft=sh:
