#!/usr/bin/env bash

set -ex

WORKDIR="$PWD"

VIMRC=".vimrc"
CURRENT_USER_VIMRC="${HOME}/${VIMRC}"

# vim and other tools must be quite new, so use versions from brew
# install brew, LLVM, nodejs and vim
which -s brew
if [[ $? != 0 ]] ; then
    # Install Homebrew
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"
else
    brew update
fi
brew install llvm vim nodejs

#generate bootstrap vim configuration
if [ ! -f "${CURRENT_USER_VIMRC}" ]; then
    curl 'https://vim-bootstrap.com/generate.vim' \
        --data 'langs=c&langs=python&langs=go&langs=&editor=vim' > "${CURRENT_USER_VIMRC}"
    #install softlinks to local.rc files into home dir
    find "$WORKDIR/vim" -type f -exec bash -c 'ln -sf $0 ~/$(basename $0)' {} \;
    vim +VimBootstrapUpdate +PlugInstall +qall
    ln -sf vim/.vim/coc-settings.json "${HOME}/.vim/coc-settings.json"
    # install coc extensions
    vim -c 'CocInstall -sync|q'
fi

#backup previous zshrc
ZSH_HOME="${HOME}/.oh-my-zsh"
if [ ! -f "${ZSH_HOME}" ]; then
    git clone https://github.com/ohmyzsh/ohmyzsh.git "${ZSH_HOME}"
    cp "${HOME}/.zshrc" "${HOME}/.zshrc.bak"
    ln -sf shell/zshrc "${HOME}/.zshrc"
    chsh -s $(which zsh)
fi

