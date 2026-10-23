#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REVISION_FILE="$REPO_ROOT/versions/oh-my-zsh"
TARGET_DIR="${OH_MY_ZSH_HOME:-$HOME/.oh-my-zsh}"
REMOTE="${OH_MY_ZSH_REPOSITORY:-https://github.com/ohmyzsh/ohmyzsh.git}"
revision="$(tr -d '[:space:]' < "$REVISION_FILE")"
# Keep a stricter caller mask, but never create group/other-writable shell code.
caller_umask="$(umask)"
umask "$(printf '%03o' "$((8#$caller_umask | 022))")"
[[ ! -L "$TARGET_DIR" ]] || { echo 'Refusing a symlinked Oh My Zsh installation directory.' >&2; exit 1; }

omz_git() {
    git -c core.sharedRepository=false -C "$TARGET_DIR" "$@"
}

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Invalid Oh My Zsh revision: $revision" >&2
    exit 1
}

mkdir -p "$TARGET_DIR"
TARGET_DIR="$(cd -- "$TARGET_DIR" && pwd -P)"
[[ "$TARGET_DIR" != / && "$TARGET_DIR" != "$(cd -- "$HOME" && pwd -P)" && "$TARGET_DIR" != "$REPO_ROOT" ]] || {
    echo 'Oh My Zsh must use a dedicated installation directory, not root, HOME, or the dotconfig checkout.' >&2
    exit 1
}
if [[ ! -d "$TARGET_DIR/.git" ]]; then
    omz_git init
    omz_git remote add origin "$REMOTE"
fi

if [[ -n "$(omz_git status --porcelain --untracked-files=no)" ]]; then
    echo "Refusing to replace tracked Oh My Zsh files with local changes: $TARGET_DIR" >&2
    exit 1
fi

omz_git fetch --depth=1 origin "$revision"
omz_git checkout --detach "$revision"

# Repair only owned managed content; do not follow links or alter custom plugins,
# Git metadata, ownership, home parents, or system completion directories.
find "$TARGET_DIR" \( -path "$TARGET_DIR/.git" -o -path "$TARGET_DIR/custom" \) -prune -o \
    \( -type d -o -type f \) -user "$(id -u)" \( -perm -020 -o -perm -002 \) \
    -exec chmod go-w {} +
bash "$REPO_ROOT/scripts/check-zsh-completions.sh" "$TARGET_DIR"

echo "Oh My Zsh pinned at $revision"
