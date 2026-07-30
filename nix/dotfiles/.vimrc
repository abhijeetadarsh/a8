" Initialize vim-plug
call plug#begin('~/.vim/plugged')

" Install Dracula theme
Plug 'dracula/vim', { 'as': 'dracula' }

" Install lightline.vim for a stylish status bar
Plug 'itchyny/lightline.vim'

" Load the plugins
call plug#end()

" Set the Dracula theme
colorscheme dracula

" Configure lightline with Dracula colors
let g:lightline = {
      \ 'colorscheme': 'dracula',
      \ 'active': {
      \   'left': [ ['mode', 'paste'], ['gitbranch', 'readonly', 'filename', 'modified'] ]
      \ },
      \ 'component_function': {
      \   'gitbranch': 'fugitive#head',
      \ },
      \ }


" Use 2 spaces in place of a tab
set tabstop=2
set shiftwidth=2
set expandtab

" Enable relative line numbers
set relativenumber
set number  " Show the absolute line number on the current line

" Enable syntax highlighting
syntax on

" Other useful settings
set smartindent  " Auto-indent new lines
set autoindent   " Keep indentation level from previous line
set showcmd      " Show partial commands in the last line of the screen
set cursorline   " Highlight the current line
set wildmenu     " Visual autocomplete for command menu
set incsearch    " Incremental search
set hlsearch     " Highlight search results
" set ignorecase   " Ignore case in search patterns
" set smartcase    " Override ignorecase if search contains capital letters
" set clipboard=unnamedplus  " Use system clipboard

set mouse=a
set laststatus=2
