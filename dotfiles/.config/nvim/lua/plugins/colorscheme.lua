-- Colourscheme.
--
-- theme_engine writes ~/.cache/theme/nvim.lua from the current wallpaper, so
-- neovim matches the terminal, the bar and the window borders. That file is
-- generated, so it can legitimately be missing - on a fresh clone, before the
-- first theme_init.sh run, or after clearing the cache - and tokyonight stays
-- installed purely as the fallback for that case.

local generated = vim.fn.expand("~/.cache/theme/nvim.lua")

local function apply_generated()
  if vim.fn.filereadable(generated) ~= 1 then
    return false
  end
  local ok, err = pcall(dofile, generated)
  if not ok then
    vim.notify("theme: could not load generated palette: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

return {
  "folke/tokyonight.nvim",
  lazy = false,
  priority = 1000,
  opts = {},
  config = function()
    require("tokyonight").setup()

    if not apply_generated() then
      vim.cmd.colorscheme("tokyonight")
    end

    -- For re-theming a running nvim after $mod+Shift+w changes the wallpaper.
    vim.api.nvim_create_user_command("ThemeReload", function()
      if apply_generated() then
        vim.notify("theme: reloaded from " .. generated)
      else
        vim.notify("theme: no generated palette found", vim.log.levels.WARN)
      end
    end, { desc = "Reload the wallpaper-derived colourscheme" })
  end,
}
