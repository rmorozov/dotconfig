#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="$HOME/.config/dotconfig"
profile="$state_dir/proxy.local"
mode_file="$state_dir/proxy.mode"

case "${1:-}" in
    on)
        [[ $# -eq 1 ]] || exit 2
        [[ -f "$profile" && -r "$profile" && ! -L "$profile" ]] || {
            echo "Create $profile with exported proxy variables first (chmod 600)." >&2
            exit 1
        }
        [[ -z "$(find "$profile" -perm -077 -print)" ]] || {
            echo "Proxy profile must not be accessible to other users: chmod 600 $profile" >&2
            exit 1
        }
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        umask 077
        printf 'on\n' > "$mode_file"
        echo 'Proxy enabled for new shells and dotconfig commands.'
        ;;
    off)
        [[ $# -eq 1 ]] || exit 2
        mkdir -p "$state_dir"
        chmod 700 "$state_dir"
        umask 077
        printf 'off\n' > "$mode_file"
        echo 'Proxy disabled for new shells and dotconfig commands.'
        ;;
    status)
        [[ $# -eq 1 ]] || exit 2
        if [[ -f "$mode_file" ]] && [[ "$(cat "$mode_file")" == on ]]; then
            if [[ -f "$profile" && -r "$profile" ]]; then
                echo 'Proxy: on'
            else
                echo 'Proxy: on (profile missing)'
                exit 1
            fi
        else
            echo 'Proxy: off'
        fi
        ;;
    *) echo 'Usage: dotconfig proxy {on|off|status}' >&2; exit 2 ;;
esac
