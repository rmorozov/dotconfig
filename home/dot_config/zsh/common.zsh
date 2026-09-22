# Shared interactive shell behavior.
export LANG="${LANG:-en_US.UTF-8}"
export ZSH_TMUX_UNICODE=true

plugins=(
    git
    golang
    colorize
    colored-man-pages
    docker
    extract
    common-aliases
    zsh-navigation-tools
    tmux
    tmux-cssh
)
