{ config, pkgs, ... }:

{
  # Your user environment, split into focused modules under ./modules.
  # This is the "dotfiles repo, the Nix way": every config below is declared
  # once here and reproduced identically on any machine you apply it to.
  imports = [
    ./modules/packages.nix
    ./modules/shell.nix
    ./modules/git.nix
    ./modules/neovim.nix
    ./modules/sway.nix
  ];

  home.username = "a8";
  home.homeDirectory = "/home/a8";

  # Keep this matching the home-manager release you track. Do NOT bump it
  # just to silence a mismatch warning - read the release notes first.
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;
  fonts.fontconfig.enable = true;
}
