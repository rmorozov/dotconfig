# macOS-specific shell integration.
if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
fi

plugins+=(brew)
alias updatedb="/usr/libexec/locate.updatedb"
