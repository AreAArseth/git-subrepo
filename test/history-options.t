#!/usr/bin/env bash

set -e
source test/setup
use Test::More

for operation in clone init migrate; do
  for option in empty-equals empty-separated invalid absent prefixed legacy; do
    repo=$OWNER/$operation-$option
    git clone -q "$UPSTREAM/init" "$repo"
    args=(doc)
    prefix=doc
    if [[ $operation == clone ]]; then
      args=("$UPSTREAM/bar" shared)
      prefix=shared
    elif [[ $operation == migrate ]]; then
      (cd "$repo" && git subrepo clone "$UPSTREAM/bar" shared --history=legacy) > /dev/null
      args=(shared)
      prefix=shared
    fi
    before=$(git -C "$repo" rev-parse HEAD)
    refs=$(git -C "$repo" show-ref)
    index=$(git hash-object "$repo/.git/index")
    options=()
    case "$option" in
      empty-equals) options=(--history=) ;;
      empty-separated) options=(--history '') ;;
      invalid) options=(--history=bogus) ;;
      prefixed) options=(--history=prefixed) ;;
      legacy) options=(--history legacy) ;;
    esac
    status=0
    (cd "$repo" && git subrepo "$operation" "${args[@]}" "${options[@]}") \
      > "$TMP/result" 2>&1 || status=$?

    case "$option" in
      empty-*|invalid)
        is "$status" 1 "$operation rejects $option history"
        like "$(cat "$TMP/result")" 'Choose --history=prefixed or --history=legacy.' \
          'history refusal lists the allowed values'
        ;;
      *)
        if [[ $operation == migrate && $option == legacy ]]; then
          is "$status" 1 'migrate still refuses legacy history removal'
          like "$(cat "$TMP/result")" 'Removing published imported history is not supported' \
            'legacy is parsed but migration keeps its existing restriction'
        else
          is "$status" 0 "$operation accepts $option history"
          if [[ $option == legacy ]]; then
            is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo.remote)" \
              "$([[ $operation == clone ]] && echo "$UPSTREAM/bar" || echo none)" \
              "$operation records legacy metadata"
            is "$(git -C "$repo" config -f "$prefix/.gitrepo" --get-regexp '^subrepo-v2\.' || true)" \
              "" "$operation does not write prefixed metadata for legacy history"
          else
            is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.history)" prefixed \
              "$operation uses prefixed history for $option"
            is "$(git -C "$repo" config -f "$prefix/.gitrepo" subrepo-v2.format)" 2 \
              "$operation records v2 metadata for $option"
          fi
        fi
        ;;
    esac

    if [[ $option == empty-* || $option == invalid ||
          ( $operation == migrate && $option == legacy ) ]]; then
      is "$(git -C "$repo" rev-parse HEAD)" "$before" 'refusal preserves parent HEAD'
      is "$(git -C "$repo" show-ref)" "$refs" 'refusal preserves repository refs'
      is "$(git hash-object "$repo/.git/index")" "$index" 'refusal preserves index bytes'
    fi
    is "$(git -C "$repo" status --porcelain --ignored)" "" \
      "$operation with $option leaves no working-tree changes or stray files"
  done
done

done_testing
teardown
