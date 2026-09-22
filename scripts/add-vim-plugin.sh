#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" -ge 1 && "$#" -le 2 ]] || {
    echo "Usage: $0 <github-owner/repository> [ref]" >&2
    exit 2
}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/vim-plugins"
BUNDLES="$REPO_ROOT/home/dot_vimrc.local.bundles"
slug="$1"
ref="${2:-HEAD}"

[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "Expected a GitHub owner/repository slug: $slug" >&2
    exit 2
}

name="${slug##*/}"
name="${name%.git}"
repository="https://github.com/$slug"
[[ "$repository" == *.git ]] || repository="$repository.git"

grep -Eq "^${name//./\.} " "$MANIFEST" && {
    echo "Plugin name already configured: $name" >&2
    exit 1
}
grep -Fq "Plug '$slug'" "$REPO_ROOT/home/dot_vimrc" || \
grep -Fq "Plug '$slug'" "$BUNDLES" || {
    printf "\n\" added with scripts/add-vim-plugin.sh\nPlug '%s'\n" "$slug" >> "$BUNDLES"
}

revision="$(git ls-remote "$repository" "$ref" | awk 'NR == 1 { print $1 }')"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Could not resolve $slug ($ref)" >&2
    exit 1
}

{
    head -n 1 "$MANIFEST"
    tail -n +2 "$MANIFEST"
    printf '%s %s %s %s\n' "$name" "$repository" "$ref" "$revision"
} | { read -r header; printf '%s\n' "$header"; LC_ALL=C sort -u; } > "$MANIFEST.tmp"
mv "$MANIFEST.tmp" "$MANIFEST"
bash "$REPO_ROOT/scripts/generate-vim-plugin-lock.sh"
echo "Added $slug at $revision"
