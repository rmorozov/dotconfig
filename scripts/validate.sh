#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

required_commands=(git shellcheck zsh)
for command_name in "${required_commands[@]}"; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing validation dependency: $command_name" >&2
        exit 1
    }
done

shell_scripts=(install.sh packages/install.sh scripts/*.sh)
shellcheck "${shell_scripts[@]}"
for script in "${shell_scripts[@]}"; do
    bash -n "$script"
done

for script in home/dot_config/zsh/*.zsh; do
    zsh -n "$script"
done

bash scripts/generate-coc-extensions.sh
bash scripts/generate-vim-plugin-lock.sh
git diff --exit-code --     home/dot_vim/coc-extensions.vim     home/dot_vim/plugin-lock.vim

test -s home/dot_vimrc
grep -q 'vim-bootstrap snapshot' home/dot_vimrc
grep -q 'call plug#begin' home/dot_vimrc
grep -q 'source ~/.vim/plugin-lock.vim' home/dot_vimrc
grep -q 'call plug#end' home/dot_vimrc
test -s home/dot_vim/plugin-lock.vim
test -s home/dot_vim/coc-extensions.vim

extension_count="$(grep -vc '^#' versions/coc-extensions)"
generated_extension_count="$(grep -c '@[0-9]' home/dot_vim/coc-extensions.vim)"
test "$extension_count" = "$generated_extension_count"
awk 'NR > 1 && $2 !~ /^[0-9]+\.[0-9]+\.[0-9]+/ { exit 1 }' versions/coc-extensions

plugin_count="$(grep -vc '^#' versions/vim-plugins)"
lock_count="$(grep -c '^call s:DotconfigPin' home/dot_vim/plugin-lock.vim)"
test "$plugin_count" = "$lock_count"
awk 'NR > 1 && $4 !~ /^[0-9a-f]{40}$/ { exit 1 }' versions/vim-plugins

grep -Eq '^[0-9a-f]{40}$' versions/oh-my-zsh

echo "Static validation passed"
