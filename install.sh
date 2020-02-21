#!/usr/bin/env bash

set -ex

WORKDIR="$PWD"

VIMRC=".vimrc"
CURRENT_USER_VIMRC="${HOME}/${VIMRC}"

#generate bootstrap vim configuration
if [ ! -f "${CURRENT_USER_VIMRC}" ]; then
    curl 'https://vim-bootstrap.com/generate.vim' \
        --data 'langs=c&langs=python&langs=go&langs=&editor=vim' > "${CURRENT_USER_VIMRC}"
    #install softlinks to local.rc files into home dir
    find "$WORKDIR/vim" -type f -exec bash -c 'ln -sf $0 ~/$(basename $0)' {} \; 
    vim +VimBootstrapUpdate +PlugInstall +qall
    ln -sf vim/.vim/coc-settings.json "${HOME}/.vim/coc-settings.json"
fi

APT_GET=/usr/bin/apt-get
# install latest stable llvm
if [ -f "${APT_GET}" ]; then
    # automation installation script from https://apt.llvm.org
    bash -c "$(wget -O - https://apt.llvm.org/llvm.sh)"
fi

