#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=/dev/null
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/home/dot_config/zsh/proxy.zsh"

case "${1:-}" in
    update) echo 'Sudo is needed to refresh the system APT package lists.' >&2 ;;
    install) echo 'Sudo is needed to install or update system packages with APT.' >&2 ;;
    *) echo 'Sudo is needed to manage system packages with APT.' >&2 ;;
esac

if command -v apt-config >/dev/null 2>&1 &&
    apt-config dump | grep -Eiq '^Acquire::(http|https)::Proxy[[:space:]]'; then
    # APT already has a persistent proxy configuration; sudo need not pass the URL.
    sudo apt-get "$@"
elif [[ -f "$HOME/.config/dotconfig/proxy.mode" ]] &&
    [[ "$(cat "$HOME/.config/dotconfig/proxy.mode")" == on ]]; then
    # sudo otherwise discards the environment used by APT's transports.
    sudo --preserve-env=http_proxy,https_proxy,no_proxy,HTTP_PROXY,HTTPS_PROXY,NO_PROXY apt-get "$@"
else
    sudo apt-get "$@"
fi
