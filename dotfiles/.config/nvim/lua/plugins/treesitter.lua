-- Syntax highlighting.
--
-- This is what the plugin manager is here for: parsers and highlight groups,
-- which the generated palette in colorscheme.lua then colours. No LSP, no
-- completion, no diagnostics.
--
-- branch = "master" is deliberate. Upstream's default branch is now `main`,
-- which is a rewrite with a different API - `nvim-treesitter.configs` does not
-- exist there, so an update that followed the default branch would silently
-- leave every buffer unhighlighted. master still carries the config API below.
--
-- Parser list is not hardcoded here - it comes from lua/lang/*.lua, one file
-- per language.
return {
  'nvim-treesitter/nvim-treesitter',
  branch = 'master',
  build = ':TSUpdate',
  config = function()
    local ensure_installed = {}
    for _, lang in ipairs(require('lang').load_all()) do
      vim.list_extend(ensure_installed, lang.treesitter or {})
    end

    require("nvim-treesitter.configs").setup({
      auto_install = true,
      ensure_installed = ensure_installed,
      highlight = { enable = true },
      indent = { enable = true },
    })
  end
}

