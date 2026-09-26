# This file is sourced by Zsh and Bash. Local proxy values are never committed.
dotconfig_proxy_dir="${HOME}/.config/dotconfig"
dotconfig_proxy_mode=unmanaged
if [[ -f "${dotconfig_proxy_dir}/proxy.mode" ]]; then
    IFS= read -r dotconfig_proxy_mode < "${dotconfig_proxy_dir}/proxy.mode" || :
fi

if [[ "$dotconfig_proxy_mode" == on ]]; then
    # Local Kerberos-aware proxy (Px, cntlm-gss, proxy-detox, etc.).
    export http_proxy='http://127.0.0.1:3128'
    export https_proxy="$http_proxy"
    export HTTP_PROXY="$http_proxy"
    export HTTPS_PROXY="$https_proxy"
    export no_proxy='localhost,127.0.0.1,::1'
    export NO_PROXY="$no_proxy"
    unset all_proxy ALL_PROXY
    if [[ -f "${dotconfig_proxy_dir}/proxy.local" ]]; then
        # The optional owner-controlled file can override the endpoint and bypass list.
        source "${dotconfig_proxy_dir}/proxy.local"
    fi
elif [[ "$dotconfig_proxy_mode" == off ]]; then
    unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
fi
unset dotconfig_proxy_dir dotconfig_proxy_mode
