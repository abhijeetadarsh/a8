return {
  treesitter = { "go", "gomod", "gowork", "gotmpl" },

  lsp = { "gopls" },

  servers = {
    gopls = {
      settings = {
        gopls = {
          gofumpt = true,
          staticcheck = true,
        },
      },
    },
  },

  -- gopls handles import fixing (goimports) as part of formatting
  format_on_save = { "*.go" },
}
