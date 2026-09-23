#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${VIM_PLUG_MANIFEST:-$REPO_ROOT/versions/vim-plug}"
target="${VIM_PLUG_TARGET:-$REPO_ROOT/home/dot_vim/autoload/plug.vim}"
snapshot="${VIM_PLUG_SNAPSHOT:-$REPO_ROOT/home/dot_vimrc}"
remote="${VIM_PLUG_REPOSITORY:-https://github.com/junegunn/vim-plug.git}"
revision="$(git ls-remote "$remote" HEAD | awk 'NR == 1 { print $1 }')"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'Could not resolve vim-plug HEAD' >&2; exit 1; }

download="$(mktemp)"
trap 'rm -f "$download"' EXIT
curl --fail --silent --show-error --location --proto '=https' --retry 3 \
    --output "$download" \
    "https://raw.githubusercontent.com/junegunn/vim-plug/$revision/plug.vim"
test -s "$download"
grep -q '^function! plug#begin' "$download"
grep -q '^function! plug#end' "$download"
blob="$(git hash-object "$download")"
if cmp -s "$download" "$target"; then
    echo 'vim-plug source is unchanged.'
    exit 0
fi
cp "$download" "$target"
printf '%s %s\n' "$revision" "$blob" > "$manifest"
VIM_PLUG_MANIFEST="$manifest" bash "$REPO_ROOT/scripts/pin-vim-plug-url.sh" "$snapshot"
echo "Pinned vim-plug at $revision"
