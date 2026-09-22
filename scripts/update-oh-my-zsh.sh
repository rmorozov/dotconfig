#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION_FILE="$REPO_ROOT/versions/oh-my-zsh"
REMOTE="${OH_MY_ZSH_REPOSITORY:-https://github.com/ohmyzsh/ohmyzsh.git}"
revision="$(git ls-remote "$REMOTE" HEAD | awk 'NR == 1 { print $1 }')"

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Could not resolve Oh My Zsh HEAD" >&2
    exit 1
}

printf '%s\n' "$revision" > "$REVISION_FILE"
echo "Pinned Oh My Zsh at $revision"
