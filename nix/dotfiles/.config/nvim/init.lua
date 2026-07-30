vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1
require("vim-options")
require("config.lazy")


vim.api.nvim_set_keymap("n", "<C-h>", "<C-w>h", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<C-j>", "<C-w>j", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<C-k>", "<C-w>k", { noremap = true, silent = true })
vim.api.nvim_set_keymap("n", "<C-l>", "<C-w>l", { noremap = true, silent = true })

-- Auto-enter Insert mode when opening a terminal
vim.cmd([[
  augroup ToggleTermInsertMode
    autocmd!
    autocmd TermOpen * startinsert
  augroup END
]])
