set number
set lisp
set expandtab
set shiftwidth=4
set softtabstop=4
set tabstop=4
set ruler
set autoindent
set smartindent
filetype plugin indent on
set showmatch
syntax on
set ruler
map <F7> mzgg=G`z<CR>
filetype indent on
set t_ut=
set t_Co=256

" Disable arrow keys
inoremap  <Up>     <NOP>
inoremap  <Down>   <NOP>
inoremap  <Left>   <NOP>
inoremap  <Right>  <NOP>
noremap   <Up>     <NOP>
noremap   <Down>   <NOP>
noremap   <Left>   <NOP>
noremap   <Right>  <NOP>

" Add syntax highlughting for Go
set rtp+=$GOROOT/misc/vim
