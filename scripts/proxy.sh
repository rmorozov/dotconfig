#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="$HOME/.config/dotconfig"
profile="$state_dir/proxy.local"
no_proxy_list="$state_dir/no-proxy.local"
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
        # Read by the sourced proxy loader.
        # shellcheck disable=SC2034
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
        # The unprivileged shell reads its own temporary payload into sudo's stdin.
        # shellcheck disable=SC2024
        sudo python3 "$file_manager" system "$action" < "$payload"
    fi
}

case "${1:-}" in
    on)
        [[ $# -eq 1 ]] || exit 2
        for local_file in "$profile" "$no_proxy_list"; do
            if [[ -e "$local_file" || -L "$local_file" ]]; then
                [[ -f "$local_file" && -r "$local_file" && ! -L "$local_file" ]] || {
                    echo "Optional proxy configuration must be a readable regular file: $local_file" >&2
                    exit 1
                }
                [[ -z "$(find "$local_file" -perm -077 -print)" ]] || {
                    echo "Proxy configuration must not be accessible to other users: chmod 600 $local_file" >&2
                    exit 1
                }
            fi
        done
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
