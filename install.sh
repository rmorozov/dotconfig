#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SKIP_PACKAGES=false
SKIP_PLUGINS=false
SKIP_SHELL_CHANGE=false
BOOTSTRAP_INSTALLER="$REPO_ROOT/scripts/install-bootstrap-tool.sh"

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Options:
  --skip-packages      Do not apply the package baseline.
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

install_chezmoi() {
    command_exists chezmoi && return

    case "$(uname -s)" in
        Darwin)
            if ! command_exists brew; then
                bash "$BOOTSTRAP_INSTALLER" homebrew
            fi
            if [[ -x /opt/homebrew/bin/brew ]]; then
                eval "$(/opt/homebrew/bin/brew shellenv)"
            elif [[ -x /usr/local/bin/brew ]]; then
                eval "$(/usr/local/bin/brew shellenv)"
            fi
            brew install chezmoi
            ;;
        Linux)
            if ! command_exists curl; then
                sudo apt-get update
                sudo apt-get install -y curl ca-certificates
            fi
            bash "$BOOTSTRAP_INSTALLER" chezmoi
            export PATH="$HOME/.local/bin:$PATH"
            ;;
        *)
            echo "Unsupported operating system: $(uname -s)" >&2
            exit 1
            ;;
    esac
}

install_mise() {
    command_exists mise && return

    case "$(uname -s)" in
        Darwin)
            brew install mise
            ;;
        Linux)
            bash "$BOOTSTRAP_INSTALLER" mise
            export PATH="$HOME/.local/bin:$PATH"
            ;;
    esac
}

install_chezmoi

if ! "$SKIP_PACKAGES"; then
    bash "$REPO_ROOT/packages/install.sh"
fi

chezmoi --source "$REPO_ROOT" init --apply

install_mise
mise install

bash "$REPO_ROOT/scripts/install-oh-my-zsh.sh"

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
echo "Review future changes with: chezmoi --source \"$REPO_ROOT\" diff"
