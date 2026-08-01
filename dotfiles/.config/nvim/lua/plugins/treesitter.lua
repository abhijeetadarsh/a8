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
return {
  'nvim-treesitter/nvim-treesitter',
  branch = 'master',
  build = ':TSUpdate',
  config = function()
    require("nvim-treesitter.configs").setup({
      auto_install = true,
      highlight = { enable = true },
      indent = { enable = true },
    })
  end
}
