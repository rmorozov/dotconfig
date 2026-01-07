#!/usr/bin/env bash

set -ex

WORKDIR="$PWD"

VIMRC=".vimrc"
CURRENT_USER_VIMRC="${HOME}/${VIMRC}"

check_command() {
    which "$1" &>/dev/null
    return $?
}

check_command vim
VIM_FOUND=$?
check_command node
NODEJS_FOUND=$?

echo "Check if versions of vim and nodejs are avaliable"
if [ ${VIM_FOUND} != 0 ] && [ ${NODEJS_FOUND} != 0 ]; then
    echo "no vim and nodejs were found, installing homebrew versions"
    # vim and other tools must be quite new, so use versions from brew
    # install brew, LLVM, nodejs and vim
    check_command brew
    BREW_FOUND=$?
    if [ ${BREW_FOUND} != 0 ] ; then
        # Install Homebrew
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
    else
        brew update
    fi
    brew install vim nodejs
    echo "vim and nodejs from homebrew were installed"
else
    echo "using already installed versions of vim and nodejs, beware of problems if they are not latest"
fi


#generate bootstrap vim configuration
if [ ! -f "${CURRENT_USER_VIMRC}" ]; then
    echo "generating vim config using vimboostrap service"
    curl 'https://vim-bootstrap.com/generate.vim' \
        --data 'langs=c&langs=python&langs=go&langs=&editor=vim&additional-plugins=fzf,vim-easymotion' > "${CURRENT_USER_VIMRC}"
    #install softlinks to local.rc files into home dir
    find "$WORKDIR/vim" -type f -exec bash -c 'ln -sf $0 ~/$(basename $0)' {} \;
    vim +VimBootstrapUpdate +PlugInstall +qall
    ln -sf ${WORKDIR}/vim/.vim/coc-settings.json "${HOME}/.vim/coc-settings.json"
    # install coc extensions
    vim -c 'CocInstall -sync|q'
else
    echo "there is current vim config=${CURRENT_USER_VIMRC} exists, please back it up, and run script again"
fi

#backup previous zshrc
ZSH_HOME="${HOME}/.oh-my-zsh"
if [ ! -e "${ZSH_HOME}" ]; then
    echo "install oh-my-zsh and back up previous zshrc to .zshrc.bak"
    git clone https://github.com/ohmyzsh/ohmyzsh.git "${ZSH_HOME}"
    if [ ! -e "${HOME}/.zshrc" ]; then
        cp "${HOME}/.zshrc" "${HOME}/.zshrc.bak"
    fi
    ln -sf shell/zshrc "${HOME}/.zshrc"
    chsh -s $(which zsh)
fi

echo "we are done"
