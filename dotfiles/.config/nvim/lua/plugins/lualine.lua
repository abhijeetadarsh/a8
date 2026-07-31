return {
  'nvim-lualine/lualine.nvim',
  dependencies = { 'nvim-tree/nvim-web-devicons' },
  config = function()
    -- "auto" derives the statusline from the active highlight groups, which
    -- means it follows the wallpaper-generated palette. It was pinned to
    -- "dracula" before, which matched nothing else on the desktop.
    require("lualine").setup({
      options = {
        theme = "auto",
        globalstatus = true,
      },
    })
  end
}
