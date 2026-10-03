#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
install_verbose=false
SKIP_PACKAGES=false
SKIP_PLUGINS=false
SKIP_SHELL_CHANGE=false
BOOTSTRAP_INSTALLER="$REPO_ROOT/scripts/install-bootstrap-tool.sh"

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Options:
  -v, --verbose       Show platform, tool paths, skip choices, and stage timings.
  --skip-packages      Do not apply the package baseline.
  --skip-plugins       Do not install or update Vim plugins.
  --skip-shell-change  Do not change the login shell.
  --user USER         Install for another existing Ubuntu/Debian account using your sudo access.
  -h, --help           Show this help.
EOF
}

original_args=("$@")
TARGET_USER=
while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
        --user)
            [[ $# -ge 2 && -n "$2" && "$2" != -* && -z "$TARGET_USER" ]] || { usage >&2; exit 2; }
            TARGET_USER="$2"
            shift
            ;;
        -v|--verbose) install_verbose=true ;;
        --skip-packages) SKIP_PACKAGES=true ;;
        --skip-plugins) SKIP_PLUGINS=true ;;
        --skip-shell-change) SKIP_SHELL_CHANGE=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ -n "$TARGET_USER" ]]; then
    exec bash "$REPO_ROOT/scripts/install-for-user.sh" "${original_args[@]}"
fi

# shellcheck source=scripts/install-progress.sh
source "$REPO_ROOT/scripts/install-progress.sh"
install_details "$REPO_ROOT"
install_step 'Loading network configuration'
# shellcheck source=/dev/null
source "$REPO_ROOT/home/dot_config/zsh/proxy.zsh"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

ensure_homebrew() {
    if ! command_exists brew; then
        echo 'Installing Homebrew; its installer may request sudo to prepare the system installation directory.' >&2
        bash "$BOOTSTRAP_INSTALLER" homebrew
    fi
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    export PATH="$HOME/.local/bin:$PATH"
}

install_chezmoi() {
    command_exists chezmoi && return

    case "$(uname -s)" in
        Darwin)
            bash "$BOOTSTRAP_INSTALLER" chezmoi
            export PATH="$HOME/.local/bin:$PATH"
            ;;
        Linux)
            if ! command_exists curl; then
                bash "$REPO_ROOT/scripts/apt-get.sh" update
                bash "$REPO_ROOT/scripts/apt-get.sh" install -y curl ca-certificates
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
            bash "$BOOTSTRAP_INSTALLER" mise
            export PATH="$HOME/.local/bin:$PATH"
            ;;
        Linux)
            bash "$BOOTSTRAP_INSTALLER" mise
            export PATH="$HOME/.local/bin:$PATH"
            ;;
    esac
}

install_step 'Preparing chezmoi and mise'
install_chezmoi
install_mise
if "$install_verbose"; then
    printf '[dotconfig] chezmoi: %s; mise: %s\n' "$(command -v chezmoi)" "$(command -v mise)" >&2
    printf '[dotconfig] Skip packages=%s, Vim plugins=%s, login shell=%s\n' "$SKIP_PACKAGES" "$SKIP_PLUGINS" "$SKIP_SHELL_CHANGE" >&2
fi

install_step 'Installing native packages'
if ! "$SKIP_PACKAGES"; then
    if [[ "$(uname -s)" == Darwin ]]; then
        ensure_homebrew
    fi
    bash "$REPO_ROOT/packages/install.sh"
else
    echo '[dotconfig] Native packages skipped by request.' >&2
fi

install_step 'Choosing profile and deploying configuration'
chezmoi --source "$REPO_ROOT" init --apply

install_step 'Installing pinned language runtimes'
bash "$REPO_ROOT/scripts/manage-runtime-versions.sh" install

install_step 'Installing pinned Oh My Zsh'
bash "$REPO_ROOT/scripts/install-oh-my-zsh.sh"

install_step 'Installing and verifying Vim plugins'
if ! "$SKIP_PLUGINS"; then
    bash "$REPO_ROOT/scripts/converge-vim.sh"
else
    echo '[dotconfig] Vim plugins skipped by request.' >&2
fi

install_step 'Selecting login shell'
if ! "$SKIP_SHELL_CHANGE"; then
    zsh_path="$(command -v zsh)"
    if [[ "${SHELL:-}" != "$zsh_path" ]]; then
        echo "Changing your login shell to $zsh_path; chsh may ask for your account password." >&2
        chsh -s "$zsh_path"
    fi
else
    echo '[dotconfig] Login-shell change skipped by request.' >&2
fi

install_step 'Recording successful installation'
if git -C "$REPO_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    git -C "$REPO_ROOT" config --local dotconfig.reviewedHead "$(git -C "$REPO_ROOT" rev-parse HEAD)"
fi

install_success 'dotconfig installation completed successfully'
echo "Review future changes with: chezmoi --source \"$REPO_ROOT\" diff"
