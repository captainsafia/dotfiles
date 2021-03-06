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

" Send more characters for redraws
set ttyfast
" Enable the mouse in all modes
set mouse=a
" Set the termianl used
set ttymouse=xterm

" Allows switching between buffers without having to save
set hidden
" Switch buffers using Ctrl + T and the buffer number
map <C-T> :buffers<CR>:buffer<Space>

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
