#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/coc-extensions"
GENERATED="$REPO_ROOT/home/dot_vim/coc-extensions.vim"
output="$(mktemp)"
trap 'rm -f "$output"' EXIT

{
    echo '" Generated from versions/coc-extensions; do not edit by hand.'
    echo 'let g:coc_global_extensions = ['
    while read -r package_name version; do
        [[ -n "${package_name:-}" && "$package_name" != "#" ]] || continue
        printf "            \\'%s@%s',\n" "$package_name" "$version"
    done < "$MANIFEST"
    echo '            \]'
} > "$output"

mv "$output" "$GENERATED"
trap - EXIT
