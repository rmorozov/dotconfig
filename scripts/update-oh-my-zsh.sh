#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION_FILE="${OH_MY_ZSH_REVISION_FILE:-$REPO_ROOT/versions/oh-my-zsh}"
REMOTE="${OH_MY_ZSH_REPOSITORY:-https://github.com/ohmyzsh/ohmyzsh.git}"
revision="$(git ls-remote "$REMOTE" HEAD | awk 'NR == 1 { print $1 }')"

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Could not resolve Oh My Zsh HEAD" >&2
    exit 1
}

candidate="$(mktemp -d)"
trap 'rm -rf "$candidate"' EXIT
git -C "$candidate" init -q
git -C "$candidate" fetch -q --depth=1 "$REMOTE" "$revision"
git -C "$candidate" checkout -q --detach FETCH_HEAD

# Evaluate the same plugin lists that the deployed .zshrc sources.
plugin_names="$(zsh -f -c '
    source "$1"
    source "$2"
    source "$3"
    print -l -- "${plugins[@]}"
' -- "$REPO_ROOT/home/dot_config/zsh/common.zsh" \
    "$REPO_ROOT/home/dot_config/zsh/linux.zsh" \
    "$REPO_ROOT/home/dot_config/zsh/darwin.zsh")"
[[ -n "$plugin_names" ]] || {
    echo "No Oh My Zsh plugins configured" >&2
    exit 1
}

while IFS= read -r plugin; do
    [[ "$plugin" =~ ^[A-Za-z0-9._-]+$ && -d "$candidate/plugins/$plugin" ]] || {
        echo "Oh My Zsh revision $revision is missing configured plugin: $plugin" >&2
        exit 1
    }
done <<< "$plugin_names"

printf '%s\n' "$revision" > "$REVISION_FILE"
echo "Pinned Oh My Zsh at $revision"
