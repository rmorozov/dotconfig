#!/usr/bin/env bash
# Install shared packages as the administrator and user files as the target account.
# shellcheck disable=SC2016 # bash -c programs expand these variables in the target process.
set -Eeuo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target_user=
skip_packages=false
skip_shell=false
user_args=(--skip-packages --skip-shell-change)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            [[ $# -ge 2 && -n "$2" && "$2" != -* && -z "$target_user" ]] || { echo 'Expected --user USER.' >&2; exit 2; }
            target_user="$2"; shift ;;
        --skip-packages) skip_packages=true ;;
        --skip-shell-change) skip_shell=true ;;
        --skip-plugins) user_args+=(--skip-plugins) ;;
        *) echo "Unknown target installation option: $1" >&2; exit 2 ;;
    esac
    shift
done
[[ "$(uname -s)" == Linux ]] || { echo '--user currently supports Ubuntu/Debian only.' >&2; exit 1; }
[[ -n "$target_user" && "$target_user" != -* ]] || { echo 'An existing target user is required.' >&2; exit 2; }
target_uid="$(id -u -- "$target_user")"
[[ "$target_uid" != 0 ]] || { echo 'Refusing to install user configuration for root.' >&2; exit 1; }
account="$(getent passwd "$target_user")"
IFS=: read -r account_name _password _uid _gid _gecos target_home _shell <<< "$account"
[[ "$account_name" == "$target_user" && "$target_home" == /* && "$target_home" != / ]] || {
    echo 'Cannot resolve a usable target home directory.' >&2; exit 1;
}
target_repo="$target_home/.local/share/dotconfig"
[[ -z "$(git -C "$repo_root" status --porcelain)" ]] || {
    echo 'Commit or stash repository changes before installing for another user.' >&2; exit 1;
}
remote_url="$(git -C "$repo_root" remote get-url origin)"
default_branch="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || printf 'origin/master')"
default_branch="${default_branch#origin/}"

as_target() {
    sudo -u "$target_user" -- env -i HOME="$target_home" USER="$target_user" LOGNAME="$target_user" \
        PATH="$target_home/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

sudo -v
# Start outside the administrator's potentially private working directory.
cd /
as_target /bin/bash -c '[[ -d "$HOME" && -w "$HOME" ]] && [[ ! -e "$1" && ! -L "$1" ]]' bash "$target_repo" || {
    echo 'Target home is not writable or its dotconfig checkout already exists; nothing installed.' >&2; exit 1;
}
if ! "$skip_packages"; then
    bash "$repo_root/packages/install.sh"
fi
# The target must never try to bootstrap curl via its own sudo access.
as_target /bin/bash -c 'command -v curl >/dev/null && command -v git >/dev/null' || {
    echo 'curl and git must be installed before user setup; omit --skip-packages.' >&2; exit 1;
}
bundle_dir="$(mktemp -d)"
trap 'rm -rf "$bundle_dir"' EXIT
git -C "$repo_root" bundle create "$bundle_dir/repo.bundle" HEAD
# Transfer only committed Git data over stdin, even when the admin checkout is private.
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
# Separate invocation retains terminal stdin for chezmoi profile prompts.
as_target /bin/bash -c 'cd "$HOME"; exec /bin/bash "$1/install.sh" "${@:2}"' bash "$target_repo" "${user_args[@]}"
if ! "$skip_shell"; then
    zsh_path="$(as_target /bin/bash -c 'command -v zsh')"
    sudo chsh -s "$zsh_path" "$target_user"
fi
echo "dotconfig installed for $target_user. Future maintenance runs as that account."
