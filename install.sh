#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKIP_PACKAGES=false
SKIP_PLUGINS=false
SKIP_SHELL_CHANGE=false

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --skip-packages      Do not install missing system packages.
  --skip-plugins       Do not install or update Vim plugins.
  --skip-shell-change  Do not change the login shell.
  -h, --help           Show this help.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --skip-packages) SKIP_PACKAGES=true ;;
        --skip-plugins) SKIP_PLUGINS=true ;;
        --skip-shell-change) SKIP_SHELL_CHANGE=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
done

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

install_packages() {
    local missing=()
    local command_name

    for command_name in git curl zsh vim node; do
        command_exists "$command_name" || missing+=("$command_name")
    done

    (("${#missing[@]}" == 0)) && return

    if "$SKIP_PACKAGES"; then
        printf 'Missing commands (package installation skipped): %s\n' "${missing[*]}" >&2
        return
    fi

    case "$(uname -s)" in
        Darwin)
            if ! command_exists brew; then
                NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            fi
            if [[ -x /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [[ -x /usr/local/bin/brew ]]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
            brew install git curl zsh vim node
            ;;
        Linux)
            if command_exists apt-get; then
                sudo apt-get update
                sudo apt-get install -y git curl zsh vim nodejs
            else
                echo "Only Ubuntu/Debian package installation is supported on Linux." >&2
                exit 1
            fi
            ;;
        *)
            echo "Unsupported operating system: $(uname -s)" >&2
            exit 1
            ;;
    esac
}

backup_and_link() {
    local source_path="$1"
    local target_path="$2"
    local backup_path="${target_path}.pre-dotconfig"

    mkdir -p "$(dirname -- "$target_path")"

    if [[ -L "$target_path" && "$(readlink "$target_path")" == "$source_path" ]]; then
        return
    fi

    if [[ -e "$target_path" || -L "$target_path" ]]; then
        if [[ ! -e "$backup_path" && ! -L "$backup_path" ]]; then
            mv -- "$target_path" "$backup_path"
            echo "Backed up $target_path to $backup_path"
        else
            rm -- "$target_path"
        fi
    fi

    ln -s -- "$source_path" "$target_path"
}

install_packages

for required_command in git curl zsh vim node; do
    if ! command_exists "$required_command"; then
        echo "Required command is unavailable: $required_command" >&2
        exit 1
    fi
done

backup_and_link "$REPO_ROOT/vim/.vimrc" "$HOME/.vimrc"
backup_and_link "$REPO_ROOT/vim/.vimrc.local" "$HOME/.vimrc.local"
backup_and_link "$REPO_ROOT/vim/.vimrc.local.bundles" "$HOME/.vimrc.local.bundles"
backup_and_link "$REPO_ROOT/vim/.vim/coc-settings.json" "$HOME/.vim/coc-settings.json"
backup_and_link "$REPO_ROOT/shell/zshrc" "$HOME/.zshrc"

OH_MY_ZSH_HOME="$HOME/.oh-my-zsh"
if [[ ! -d "$OH_MY_ZSH_HOME/.git" ]]; then
    git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "$OH_MY_ZSH_HOME"
fi

if ! "$SKIP_PLUGINS"; then
    vim -Nu "$HOME/.vimrc" -n -es \
        +'silent! PlugInstall --sync' \
        +'silent! CocInstall -sync' \
        +qall
fi

if ! "$SKIP_SHELL_CHANGE"; then
    zsh_path="$(command -v zsh)"
    if [[ "${SHELL:-}" != "$zsh_path" ]]; then
        chsh -s "$zsh_path"
    fi
fi

echo "dotconfig installation complete"
