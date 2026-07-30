{ config, ... }:

# Your existing dotfiles, placed verbatim - "exactly this".
#
# We use mkOutOfStoreSymlink so ~/.config/i3 (etc.) symlink to the LIVE files in
# this repo, not to a read-only copy in the nix store. That matters here because
# your setup writes into its own config dirs at runtime (polybar's theme-engine
# generates ~/.config/polybar/shades, lazy.nvim writes lazy-lock, vim-plug
# writes ~/.vim/plugged). A store copy would be read-only and break them.
#
# Consequence: this repo must live at ~/arch-nix-setup (adjust `repo` below if
# you clone it elsewhere). Editing a file in the repo changes your live config
# immediately - no `home-manager switch` needed for config edits.

let
  repo = "${config.home.homeDirectory}/arch-nix-setup/nix/dotfiles";
  link = path: config.lib.file.mkOutOfStoreSymlink "${repo}/${path}";
in
{
  xdg.enable = true;

  xdg.configFile = {
    "i3".source = link ".config/i3";
    "polybar".source = link ".config/polybar";
    "rofi".source = link ".config/rofi";
    "picom".source = link ".config/picom";
    "alacritty".source = link ".config/alacritty";
    "kitty".source = link ".config/kitty";
    "nvim".source = link ".config/nvim";
    "gtk-3.0".source = link ".config/gtk-3.0";
    "gtk-4.0".source = link ".config/gtk-4.0";
    "starship.toml".source = link ".config/starship.toml";
  };

  home.file = {
    ".bashrc".source = link ".bashrc";
    ".Xresources".source = link ".Xresources";
    ".vimrc".source = link ".vimrc";
    ".vim".source = link ".vim";
    ".gitconfig".source = link ".gitconfig";

    # You had no ~/.xinitrc; this starts i3 from a tty via `startx`.
    ".xinitrc" = {
      executable = true;
      text = ''
        #!/bin/sh
        [ -f "$HOME/.Xresources" ] && xrdb -merge "$HOME/.Xresources"
        exec i3
      '';
    };
  };
}
