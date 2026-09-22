#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/vim-plugins"
LOCK_FILE="$REPO_ROOT/home/dot_vim/plugin-lock.vim"
updated="$(mktemp)"
lock="$(mktemp)"
trap 'rm -f "$updated" "$lock"' EXIT

printf '%s\n' '# name repository ref commit' > "$updated"
while read -r name repository ref _commit; do
    [[ -n "${name:-}" && "$name" != "#" ]] || continue
    revision="$(git ls-remote "$repository" "$ref" | awk 'NR == 1 { print $1 }')"
    [[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
        echo "Could not resolve $name from $repository ($ref)" >&2
        exit 1
    }
    printf '%s %s %s %s\n' "$name" "$repository" "$ref" "$revision" >> "$updated"
done < "$MANIFEST"

{
    echo '" Generated from versions/vim-plugins; do not edit by hand.'
    echo 'function! s:DotconfigPin(name, commit) abort'
    echo '  if has_key(g:plugs, a:name)'
    echo '    let g:plugs[a:name].commit = a:commit'
    echo '  endif'
    echo 'endfunction'
    echo
    while read -r name _repository _ref commit; do
        [[ -n "${name:-}" && "$name" != "#" ]] || continue
        printf "call s:DotconfigPin('%s', '%s')\n" "$name" "$commit"
    done < "$updated"
    echo
    echo 'delfunction s:DotconfigPin'
} > "$lock"

mv "$updated" "$MANIFEST"
mv "$lock" "$LOCK_FILE"
trap - EXIT
