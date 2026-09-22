" Generated from versions/vim-plugins; do not edit by hand.
function! s:DotconfigPin(name, commit) abort
  if has_key(g:plugs, a:name)
    let g:plugs[a:name].commit = a:commit
  endif
endfunction

call s:DotconfigPin('nerdtree', '690d061b591525890f1471c6675bcb5bdc8cdff9')
call s:DotconfigPin('vim-nerdtree-tabs', '07d19f0299762669c6f93fbadb8249da6ba9de62')
call s:DotconfigPin('vim-commentary', '64a654ef4a20db1727938338310209b6a63f60c9')
call s:DotconfigPin('vim-fugitive', '3b753cf8c6a4dcde6edee8827d464ba9b8c4a6f0')
call s:DotconfigPin('vim-airline', 'ae24f4aca06731d5d7224df1fc5415975331b214')
call s:DotconfigPin('vim-airline-themes', '77aab8c6cf7179ddb8a05741da7e358a86b2c3ab')
call s:DotconfigPin('vim-gitgutter', '90b75207bd9b55d8ac4af15f72b4e935462014d0')
call s:DotconfigPin('grep.vim', '852ddb0c6590bbc41c508d7f5d2fc17112492def')
call s:DotconfigPin('CSApprox', 'a2958096696f9132ef0ece44b3fab93dac6df8d0')
call s:DotconfigPin('delimitMate', 'becbd2d353a2366171852387288ebb4b33a02487')
call s:DotconfigPin('tagbar', '07cb8247487208124978daff8e13624667635457')
call s:DotconfigPin('ale', 'e1789bc54483d76ac9ddb40b633d1645c8281914')
call s:DotconfigPin('indentLine', 'b96a75985736da969ac38b72a7716a8c57bdde98')
call s:DotconfigPin('vim-bootstrap-updater', '55d9d5794a391cd23f9c0d76336a30aeac0e9c70')
call s:DotconfigPin('vim-rhubarb', '5496d7c94581c4c9ad7430357449bb57fc59f501')
call s:DotconfigPin('molokai', 'c67bdfcdb31415aa0ade7f8c003261700a885476')
call s:DotconfigPin('fzf.vim', '8a0068127ac9ee23d71dab2944ce995726bef462')
call s:DotconfigPin('fzf', 'b1be3a8be1b833ce5b92fbbac11637643d60a046')
call s:DotconfigPin('vimproc.vim', '63a4ce0768c7af434ac53d37bdc1e7ff7fd2bece')
call s:DotconfigPin('vim-misc', '3e6b8fb6f03f13434543ce1f5d24f6a5d3f34f0b')
call s:DotconfigPin('vim-session', '9e9a6088f0554f6940c19889d0b2a8f39d13f2bb')
call s:DotconfigPin('ultisnips', '0ca6a21386021e74a91034365809dcca56ed13f0')
call s:DotconfigPin('vim-snippets', 'ededcf7581962ee616cadab360d5966f3307f11a')
call s:DotconfigPin('c.vim', '69f0368c7d8dac196bd94ddfa80d98b1cedc7eb0')
call s:DotconfigPin('split-manpage.vim', 'e99c7a06e2f3f86218c8849bccf4bd1ec2736422')
call s:DotconfigPin('vim-go', '47694979496d4bf2e90ce75d95f1dec3f41cbefb')
call s:DotconfigPin('jedi-vim', 'a13c7bf64dbb4abcf676b4e41c5fedc2d4e7f6dd')
call s:DotconfigPin('requirements.txt.vim', 'd55452136a162ac31b15876ab98c00bd1b6c312f')
call s:DotconfigPin('coc.nvim', '93841afaba00209eadd72674f95c6ed398ef923d')
call s:DotconfigPin('vim-trailing-whitespace', 'dc22ff46010e55d2c33edd21cdcd14f99e729b6f')

delfunction s:DotconfigPin
