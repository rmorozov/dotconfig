# This file is sourced by Zsh and Bash. Local proxy values are never committed.
dotconfig_proxy_dir="${HOME}/.config/dotconfig"
dotconfig_proxy_mode=unmanaged
if [[ -f "${dotconfig_proxy_dir}/proxy.mode" ]]; then
    IFS= read -r dotconfig_proxy_mode < "${dotconfig_proxy_dir}/proxy.mode" || :
fi

if [[ "$dotconfig_proxy_mode" == on && -f "${dotconfig_proxy_dir}/proxy.local" ]]; then
    # The owner-controlled file may export proxy URLs and certificate variables.
    source "${dotconfig_proxy_dir}/proxy.local"
elif [[ "$dotconfig_proxy_mode" == off ]]; then
    unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
fi
unset dotconfig_proxy_dir dotconfig_proxy_mode
