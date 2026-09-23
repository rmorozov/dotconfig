#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

vim -Nu "$HOME/.vimrc" -n -es \
    +'PlugInstall --sync' \
    +'CocInstall -sync' \
    +qall

# Vim can complete an Ex session even when a plugin command was ineffective.
# Confirm the installed manager, Git revisions, and CoC versions before success.
bash "$REPO_ROOT/scripts/check-editor-state.sh"
