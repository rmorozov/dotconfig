#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/coc-extensions"
GENERATED="$REPO_ROOT/home/dot_vim/coc-extensions.vim"
updated="$(mktemp)"
output="$(mktemp)"
trap 'rm -f "$updated" "$output"' EXIT

printf '%s\n' '# npm package version' > "$updated"
while read -r package_name _version; do
    [[ -n "${package_name:-}" && "$package_name" != "#" ]] || continue
    version="$(npm view "$package_name" version --silent)"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$ ]] || {
        echo "Could not resolve $package_name" >&2
        exit 1
    }
    printf '%s %s\n' "$package_name" "$version" >> "$updated"
done < "$MANIFEST"

{
    echo '" Generated from versions/coc-extensions; do not edit by hand.'
    echo 'let g:coc_global_extensions = ['
    while read -r package_name version; do
        [[ -n "${package_name:-}" && "$package_name" != "#" ]] || continue
        printf "            \\'%s@%s',\n" "$package_name" "$version"
    done < "$updated"
    echo '            \]'
} > "$output"

mv "$updated" "$MANIFEST"
mv "$output" "$GENERATED"
trap - EXIT
