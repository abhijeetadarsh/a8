{ pkgs, ... }:

# neovim, configured declaratively. For a small config the inline extraConfig
# below is enough; if you have a big existing nvim setup you'd rather keep
# verbatim, see docs/dotfiles-with-nix.md for the symlink approach.
{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    extraConfig = ''
      set number relativenumber
      set expandtab shiftwidth=2 tabstop=2 smartindent
      set ignorecase smartcase
      set clipboard=unnamedplus
      set termguicolors
      set scrolloff=5
    '';

    # plugins you want managed by nix (optional):
    # plugins = with pkgs.vimPlugins; [ telescope-nvim nvim-treesitter ];
  };
}
