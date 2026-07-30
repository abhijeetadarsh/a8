{ config, pkgs, ... }:

{
  # Your user environment. This mirrors your existing i3 dotfiles exactly:
  #   packages.nix  - every program your configs invoke
  #   dotfiles.nix  - your config files, symlinked verbatim from ./dotfiles
  imports = [
    ./modules/packages.nix
    ./modules/dotfiles.nix
  ];

  home.username = "a8";
  home.homeDirectory = "/home/a8";

  # Keep this matching the home-manager release you track. Do NOT bump it
  # just to silence a mismatch warning - read the release notes first.
  home.stateVersion = "25.05";

  programs.home-manager.enable = true;
  fonts.fontconfig.enable = true;
}
