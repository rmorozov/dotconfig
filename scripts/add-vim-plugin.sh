#!/usr/bin/env bash
set -Eeuo pipefail

[[ "$#" -ge 1 && "$#" -le 3 ]] || {
    echo "Usage: $0 <github-owner/repository> [ref] [home-relative-dir]" >&2
    exit 2
}

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/versions/vim-plugins"
BUNDLES="$REPO_ROOT/home/dot_vimrc.local.bundles"
LOCATIONS="$REPO_ROOT/versions/vim-plugin-locations"
slug="$1"
ref="${2:-HEAD}"
home_dir="${3:-}"

[[ "$slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
    echo "Expected a GitHub owner/repository slug: $slug" >&2
    exit 2
}

[[ "$ref" =~ ^[A-Za-z0-9._/-]+$ ]] || {
    echo "Invalid Git ref: $ref" >&2
    exit 2
}
if [[ -n "$home_dir" ]]; then
    if ! [[ "$home_dir" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ ]] ||
        [[ "$home_dir" == .. || "$home_dir" == ../* ||
           "$home_dir" == */../* || "$home_dir" == */.. ]]; then
        echo "Expected a safe home-relative directory: $home_dir" >&2
        exit 2
    fi
fi

name="${slug##*/}"
name="${name%.git}"
repository="https://github.com/$slug"
[[ "$repository" == *.git ]] || repository="$repository.git"

awk -v name="$name" '$1 == name { found=1 } END { exit !found }' "$MANIFEST" && {
    echo "Plugin name already configured: $name" >&2
    exit 1
}
if [[ -n "$home_dir" ]] &&
    { grep -Fq "Plug '$slug'" "$REPO_ROOT/home/dot_vimrc" ||
      grep -Fq "Plug '$slug'" "$BUNDLES"; }; then
    echo "Custom directory needs a new Plug declaration: $slug" >&2
    exit 1
fi
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
if [[ -n "$home_dir" ]]; then
    printf '%s %s\n' "$name" "$home_dir" >> "$LOCATIONS"
    printf "\n\" added with scripts/add-vim-plugin.sh\nPlug '%s', { 'dir': '~/%s' }\n" \
        "$slug" "$home_dir" >> "$BUNDLES"
elif ! grep -Fq "Plug '$slug'" "$REPO_ROOT/home/dot_vimrc" &&
     ! grep -Fq "Plug '$slug'" "$BUNDLES"; then
    printf "\n\" added with scripts/add-vim-plugin.sh\nPlug '%s'\n" "$slug" >> "$BUNDLES"
fi

echo "Added $slug at $revision"
