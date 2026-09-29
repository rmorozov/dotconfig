# This file is sourced by Zsh and Bash. Local proxy values are never committed.
dotconfig_proxy_dir="${HOME}/.config/dotconfig"
dotconfig_proxy_mode=unmanaged
if [[ -f "${dotconfig_proxy_dir}/proxy.mode" ]]; then
    IFS= read -r dotconfig_proxy_mode < "${dotconfig_proxy_dir}/proxy.mode" || :
fi
if [[ "${DOTCONFIG_PROXY_MODE_OVERRIDE:-}" == on ]]; then
    dotconfig_proxy_mode=on
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
    # Extend the active bypass list with one host, suffix, or address per line.
    # Preserve the loopback defaults even if a private profile replaces no_proxy.
    dotconfig_proxy_bypass="localhost,127.0.0.1,::1"
    dotconfig_proxy_pending="${no_proxy:-},${NO_PROXY:-}"
    while [[ -n "$dotconfig_proxy_pending" ]]; do
        dotconfig_proxy_item="${dotconfig_proxy_pending%%,*}"
        if [[ "$dotconfig_proxy_pending" == *,* ]]; then
            dotconfig_proxy_pending="${dotconfig_proxy_pending#*,}"
        else
            dotconfig_proxy_pending=''
        fi
        if [[ -n "$dotconfig_proxy_item" && ",$dotconfig_proxy_bypass," != *",$dotconfig_proxy_item,"* ]]; then
            dotconfig_proxy_bypass+=",$dotconfig_proxy_item"
        fi
    done
    if [[ -f "${dotconfig_proxy_dir}/no-proxy.local" ]]; then
        while IFS= read -r dotconfig_proxy_item || [[ -n "$dotconfig_proxy_item" ]]; do
            case "$dotconfig_proxy_item" in
                ''|\#*) continue ;;
                *[!a-zA-Z0-9._:/*-]*)
                    echo 'Ignoring invalid entry in no-proxy.local' >&2
                    continue ;;
            esac
            if [[ ",$dotconfig_proxy_bypass," != *",$dotconfig_proxy_item,"* ]]; then
                dotconfig_proxy_bypass+=",$dotconfig_proxy_item"
            fi
        done < "${dotconfig_proxy_dir}/no-proxy.local"
    fi
    export no_proxy="$dotconfig_proxy_bypass"
    export NO_PROXY="$dotconfig_proxy_bypass"
    unset dotconfig_proxy_bypass dotconfig_proxy_pending dotconfig_proxy_item
elif [[ "$dotconfig_proxy_mode" == off ]]; then
    unset http_proxy https_proxy all_proxy no_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY
fi
unset dotconfig_proxy_dir dotconfig_proxy_mode
