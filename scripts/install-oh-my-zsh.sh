#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION_FILE="$REPO_ROOT/versions/oh-my-zsh"
TARGET_DIR="${OH_MY_ZSH_HOME:-$HOME/.oh-my-zsh}"
REMOTE="${OH_MY_ZSH_REPOSITORY:-https://github.com/ohmyzsh/ohmyzsh.git}"
revision="$(tr -d '[:space:]' < "$REVISION_FILE")"

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Invalid Oh My Zsh revision: $revision" >&2
    exit 1
}

if [[ ! -d "$TARGET_DIR/.git" ]]; then
    mkdir -p "$TARGET_DIR"
    git -C "$TARGET_DIR" init
    git -C "$TARGET_DIR" remote add origin "$REMOTE"
fi

if [[ -n "$(git -C "$TARGET_DIR" status --porcelain --untracked-files=no)" ]]; then
    echo "Refusing to replace tracked Oh My Zsh files with local changes: $TARGET_DIR" >&2
    exit 1
fi

git -C "$TARGET_DIR" fetch --depth=1 origin "$revision"
git -C "$TARGET_DIR" checkout --detach "$revision"

echo "Oh My Zsh pinned at $revision"
