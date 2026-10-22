#!/usr/bin/env bash
# shellcheck disable=SC2016 # The quoted program runs in Zsh, not this shell.
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
command -v zsh >/dev/null || { echo 'Cannot audit completions: zsh is missing.' >&2; exit 1; }
exec zsh -f -c '
    repo_root=$1
    omz=$2
    custom=${ZSH_CUSTOM:-$omz/custom}
    source "$repo_root/home/dot_config/zsh/common.zsh" || exit
    case $OSTYPE in
        darwin*) source "$repo_root/home/dot_config/zsh/darwin.zsh" || exit ;;
        linux-gnu*) source "$repo_root/home/dot_config/zsh/linux.zsh" || exit ;;
    esac
    fpath=("$omz/functions" "$omz/completions" "$custom/functions" "$custom/completions" $fpath)
    for plugin in $plugins; do
        if [[ -d "$custom/plugins/$plugin" ]]; then
            fpath=("$custom/plugins/$plugin" $fpath)
        elif [[ -d "$omz/plugins/$plugin" ]]; then
            fpath=("$omz/plugins/$plugin" $fpath)
        fi
    done
    autoload -Uz compaudit
    if result=$(compaudit 2>&1); then
        print -r -- "Zsh completion permissions: OK"
    else
        print -u2 -r -- "$result"
        print -u2 -r -- "Zsh completion audit failed. Inspect the listed paths and their parents with ls -ld and namei -l (Linux)."
        print -u2 -r -- "Completion code must have a trusted owner and must not be group/other writable. Repair only the affected paths; system paths may require an administrator."
        print -u2 -r -- "Custom completion paths and ownership are not changed automatically. Keep ZSH_DISABLE_COMPFIX unset and restart Zsh after repair."
        exit 1
    fi
' -- "$repo_root" "${1:-${OH_MY_ZSH_HOME:-$HOME/.oh-my-zsh}}"
