return {
  treesitter = { "c", "cpp" },

  lsp = { "clangd" },

  servers = {
    -- clangd's own defaults (cmd, filetypes, root markers) are fine as-is.
    clangd = {},
  },

  format_on_save = { "*.c", "*.h", "*.cpp", "*.hpp", "*.cc", "*.cxx" },
}
