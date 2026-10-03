#!/usr/bin/env bash
# Install shared packages as the administrator and user files as the target account.
# shellcheck disable=SC2016 # bash -c programs expand these variables in the target process.
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target_user=
install_verbose=false
resume=false
skip_packages=false
skip_shell=false
user_args=(--skip-packages --skip-shell-change)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            [[ $# -ge 2 && -n "$2" && "$2" != -* && -z "$target_user" ]] || { echo 'Expected --user USER.' >&2; exit 2; }
            target_user="$2"; shift ;;
        --resume) resume=true ;;
        -v|--verbose) install_verbose=true; user_args+=(--verbose) ;;
        --skip-packages) skip_packages=true ;;
        --skip-shell-change) skip_shell=true ;;
        --skip-plugins) user_args+=(--skip-plugins) ;;
        *) echo "Unknown target installation option: $1" >&2; exit 2 ;;
    esac
    shift
done
# shellcheck source=scripts/install-progress.sh
source "$repo_root/scripts/install-progress.sh"
install_details "$repo_root"
install_step 'Checking target account and source checkout'
[[ "$(uname -s)" == Linux ]] || { echo '--user currently supports Ubuntu/Debian only.' >&2; exit 1; }
command -v apt-get >/dev/null || { echo '--user requires Ubuntu/Debian with APT.' >&2; exit 1; }
[[ -n "$target_user" && "$target_user" != -* ]] || { echo 'An existing target user is required.' >&2; exit 2; }
target_uid="$(id -u -- "$target_user")"
[[ "$target_uid" != 0 ]] || { echo 'Refusing to install user configuration for root.' >&2; exit 1; }
account="$(getent passwd "$target_user")"
IFS=: read -r account_name _password _uid _gid _gecos target_home _shell <<< "$account"
[[ "$account_name" == "$target_user" && "$target_home" == /* && "$target_home" != / ]] || {
    echo 'Cannot resolve a usable target home directory.' >&2; exit 1;
}
target_repo="$target_home/.local/share/dotconfig"
source_status="$(git -C "$repo_root" status --porcelain)"
[[ -z "$source_status" ]] || {
    echo 'Commit or stash repository changes before installing for another user.' >&2; exit 1;
}
remote_url="$(git -C "$repo_root" remote get-url origin)"
default_branch="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || printf 'origin/master')"
default_branch="${default_branch#origin/}"
git -C "$repo_root" merge-base --is-ancestor HEAD "refs/remotes/origin/$default_branch" || {
    echo 'Source HEAD must be an ancestor of the fetched origin default branch; fetch it and use a reviewed default-branch checkout.' >&2
    exit 1
}

install_step 'Preparing target network environment'
target_env=("HOME=$target_home" "USER=$target_user" "LOGNAME=$target_user"
    "PATH=$target_home/.local/bin:/usr/local/bin:/usr/bin:/bin")
if [[ -f "$HOME/.config/dotconfig/proxy.mode" ]] &&
    [[ "$(cat "$HOME/.config/dotconfig/proxy.mode")" == on ]]; then
    # Only allow-listed, validated network settings cross the account boundary.
    # The administrator's private shell profile runs only in this subshell.
    proxy_assignments="$(
        # shellcheck source=/dev/null
        source "$repo_root/home/dot_config/zsh/proxy.zsh" >/dev/null || exit
        python3 "$repo_root/scripts/proxy-files.py" environment on
    )"
    while IFS= read -r assignment; do
        target_env+=("$assignment")
    done <<< "$proxy_assignments"
fi

as_target() {
    sudo -u "$target_user" -- env -i "${target_env[@]}" "$@"
}

echo "Sudo is needed to run setup as $target_user using your administrator account." >&2
install_step 'Checking administrator access and target home'
sudo -v
# Start outside the administrator's potentially private working directory.
cd /
echo "Using sudo to check $target_user's home directory before installation." >&2
as_target /bin/bash -c '[[ -d "$HOME" && -w "$HOME" ]]' || {
    echo 'Target home is not writable; nothing installed.' >&2; exit 1;
}
if "$resume"; then
    install_step 'Verifying existing target checkout for resume'
    target_head="$(as_target /bin/bash -c '
        set -Eeuo pipefail
        [[ -d "$1/.git" && ! -L "$1" && ! -L "$1/.git" && -f "$1/install.sh" ]] || exit 1
        [[ "$(cd "$(git -C "$1" rev-parse --show-toplevel)" && pwd -P)" == "$(cd "$1" && pwd -P)" ]] || exit 1
        [[ "$(git -C "$1" remote get-url origin)" == "$2" ]] || exit 1
        [[ -z "$(git -C "$1" status --porcelain)" ]] || exit 1
        git -C "$1" rev-parse HEAD
    ' bash "$target_repo" "$remote_url")" || {
        echo 'Resume requires an existing clean dotconfig checkout with the same origin; nothing installed.' >&2; exit 1;
    }
    git -C "$repo_root" merge-base --is-ancestor "$target_head" "refs/remotes/origin/$default_branch" || {
        echo 'Target revision is not in the fetched reviewed default branch; fetch origin and inspect the checkout before resuming.' >&2; exit 1;
    }
    echo 'Reusing the existing target checkout without resetting or updating it.' >&2
else
    as_target /bin/bash -c '[[ ! -e "$1" && ! -L "$1" ]]' bash "$target_repo" || {
        echo 'Target dotconfig checkout already exists; use --user USER --resume to retry a failed installation.' >&2; exit 1;
    }
fi
install_step 'Installing shared native packages'
if ! "$skip_packages"; then
    bash "$repo_root/packages/install.sh"
fi
if ! "$skip_shell"; then
    zsh_path="$(PATH=/usr/bin:/bin command -v zsh || true)"
    if [[ "$zsh_path" != /* || ! -x "$zsh_path" ]] || ! grep -Fxq -- "$zsh_path" /etc/shells; then
        echo 'System zsh must be executable and listed in /etc/shells; login shell unchanged.' >&2
        exit 1
    fi
fi
install_step 'Checking target system tools and login shell'
# The target must never try to bootstrap curl via its own sudo access.
echo "Using sudo to check the tools available to $target_user." >&2
as_target /bin/bash -c 'command -v curl >/dev/null && command -v git >/dev/null' || {
    echo 'curl and git must be installed before user setup; omit --skip-packages.' >&2; exit 1;
}
if ! "$resume"; then
install_step 'Transferring committed checkout to target account'
bundle_dir="$(mktemp -d)"
trap 'rm -rf "$bundle_dir"' EXIT
git -C "$repo_root" bundle create "$bundle_dir/repo.bundle" HEAD
# Transfer only committed Git data over stdin, even when the admin checkout is private.
echo "Using sudo to create the dotconfig checkout owned by $target_user." >&2
as_target /bin/bash -c '
    set -Eeuo pipefail
    umask 077
    cd "$HOME"
    tmp="$(mktemp -d)"
    trap '\''rm -rf "$tmp"'\'' EXIT
    cat > "$tmp/repo.bundle"
    mkdir -p "$(dirname -- "$1")"
    git -c advice.detachedHead=false clone "$tmp/repo.bundle" "$1"
    git -C "$1" checkout -B "$3"
    git -C "$1" remote set-url origin "$2"
    git -C "$1" config "branch.$3.remote" origin
    git -C "$1" config "branch.$3.merge" "refs/heads/$3"
' bash "$target_repo" "$remote_url" "$default_branch" < "$bundle_dir/repo.bundle"
fi
install_step 'Installing target configuration and runtimes'
# Separate invocation retains terminal stdin for chezmoi profile prompts.
echo "Using sudo to install dotfiles, runtimes, and plugins as $target_user." >&2
as_target /bin/bash -c 'cd "$HOME"; exec /bin/bash "$1/install.sh" "${@:2}"' bash "$target_repo" "${user_args[@]}"
install_step 'Selecting target login shell'
if ! "$skip_shell"; then
    echo "Using sudo to change $target_user's login shell to $zsh_path." >&2
    sudo chsh -s "$zsh_path" "$target_user"
fi
install_success "dotconfig installation completed successfully for $target_user"
echo "Future maintenance runs as $target_user."
