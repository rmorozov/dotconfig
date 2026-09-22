#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/vim-plugins"
LOCK_FILE="$REPO_ROOT/home/dot_vim/plugin-lock.vim"
output="$(mktemp)"
trap 'rm -f "$output"' EXIT

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
    done < "$MANIFEST"
    echo
    echo 'delfunction s:DotconfigPin'
} > "$output"

mv "$output" "$LOCK_FILE"
trap - EXIT
