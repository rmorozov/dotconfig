#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="$HOME/.config/dotconfig"
profile="$state_dir/proxy.local"
mode_file="$state_dir/proxy.mode"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
file_manager="$repo_root/scripts/proxy-files.py"

configure_files() {
    local action="$1"
    local payload
    payload="$(mktemp)"
    chmod 600 "$payload"
    trap 'rm -f "$payload"' RETURN
    if [[ "$action" == on ]]; then
        DOTCONFIG_PROXY_MODE_OVERRIDE=on
        # shellcheck source=/dev/null
        source "$repo_root/home/dot_config/zsh/proxy.zsh"
        unset DOTCONFIG_PROXY_MODE_OVERRIDE
        python3 "$file_manager" payload on > "$payload"
    fi
    python3 "$file_manager" user "$action" < "$payload"
    if [[ -n "${DOTCONFIG_PROXY_TEST_ROOT:-}" ]]; then
        python3 "$file_manager" system "$action" "$DOTCONFIG_PROXY_TEST_ROOT" < "$payload"
    elif [[ "$(uname -s)" == Linux ]]; then
        sudo python3 "$file_manager" system "$action" < "$payload"
    fi
}

case "${1:-}" in
    on)
        [[ $# -eq 1 ]] || exit 2
        if [[ -e "$profile" || -L "$profile" ]]; then
            [[ -f "$profile" && -r "$profile" && ! -L "$profile" ]] || {
                echo "Optional proxy profile must be a readable regular file: $profile" >&2
                exit 1
            }
            [[ -z "$(find "$profile" -perm -077 -print)" ]] || {
                echo "Proxy profile must not be accessible to other users: chmod 600 $profile" >&2
                exit 1
            }
        fi
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        configure_files on
        umask 077
        printf 'on\n' > "$mode_file"
        echo 'Proxy enabled (127.0.0.1:3128 by default) for new shells and dotconfig commands.'
        ;;
    off)
        [[ $# -eq 1 ]] || exit 2
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        configure_files off
        umask 077
        printf 'off\n' > "$mode_file"
        echo 'Proxy disabled for new shells and dotconfig commands.'
        ;;
    status)
        [[ $# -eq 1 ]] || exit 2
        if [[ -f "$mode_file" ]] && [[ "$(cat "$mode_file")" == on ]]; then
            echo 'Proxy: on (127.0.0.1:3128 by default; listener not checked)'
        else
            echo 'Proxy: off'
        fi
        ;;
    *) echo 'Usage: dotconfig proxy {on|off|status}' >&2; exit 2 ;;
esac
