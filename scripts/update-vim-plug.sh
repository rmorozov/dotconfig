#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="${VIM_PLUG_MANIFEST:-$REPO_ROOT/versions/vim-plug}"
target="${VIM_PLUG_TARGET:-$REPO_ROOT/home/dot_vim/autoload/plug.vim}"
snapshot="${VIM_PLUG_SNAPSHOT:-$REPO_ROOT/home/dot_vimrc}"
remote="${VIM_PLUG_REPOSITORY:-https://github.com/junegunn/vim-plug.git}"
revision="$(git ls-remote "$remote" HEAD | awk 'NR == 1 { print $1 }')"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'Could not resolve vim-plug HEAD' >&2; exit 1; }

staged="$(mktemp -d)"
trap 'rm -rf "$staged"' EXIT
curl --fail --silent --show-error --location --proto '=https' --retry 3 \
    --output "$staged/plug.vim" \
    "https://raw.githubusercontent.com/junegunn/vim-plug/$revision/plug.vim"
test -s "$staged/plug.vim"
grep -q '^function! plug#begin' "$staged/plug.vim"
grep -q '^function! plug#end' "$staged/plug.vim"
blob="$(git hash-object "$staged/plug.vim")"
read -r current_revision current_blob < "$manifest"

# Keep the reviewed revision when HEAD moves without changing plug.vim.
# A mismatched manifest or fallback URL is still repaired on the next run.
if cmp -s "$staged/plug.vim" "$target" && [[ "$current_blob" == "$blob" && "$current_revision" =~ ^[0-9a-f]{40}$ ]]; then
    revision="$current_revision"
fi
printf '%s %s\n' "$revision" "$blob" > "$staged/manifest"
cp "$snapshot" "$staged/snapshot"
VIM_PLUG_MANIFEST="$staged/manifest" bash "$REPO_ROOT/scripts/pin-vim-plug-url.sh" "$staged/snapshot"

if cmp -s "$staged/plug.vim" "$target" && \
    cmp -s "$staged/manifest" "$manifest" && \
    cmp -s "$staged/snapshot" "$snapshot"; then
    echo 'vim-plug pin and snapshot are unchanged.'
    exit 0
fi

cp "$staged/plug.vim" "$target"
cp "$staged/manifest" "$manifest"
cp "$staged/snapshot" "$snapshot"
echo "Pinned vim-plug at $revision"
