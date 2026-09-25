-- Discovers and loads every per-language spec in lua/lang/*.lua.
--
-- Each language file returns a plain table:
--   treesitter     - list of parser names to install
--   lsp            - list of mason package names to ensure installed
--   servers        - { [lspconfig server name] = vim.lsp.config() opts }
--   format_on_save - list of file patterns to format on BufWritePre
--
-- To drop a language, delete its file here; nothing else references it.
local M = {}

function M.load_all()
  local languages = {}
  local dir = vim.fn.stdpath("config") .. "/lua/lang"

  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.lua$") and name ~= "init.lua" then
      local mod_name = name:gsub("%.lua$", "")
      local ok, lang = pcall(require, "lang." .. mod_name)
      if ok then
        table.insert(languages, lang)
      else
        vim.notify("lang." .. mod_name .. " failed to load:\n" .. lang, vim.log.levels.ERROR)
      end
    end
  end

  return languages
end

return M
