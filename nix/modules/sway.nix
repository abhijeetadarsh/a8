{ pkgs, ... }:

# Sway (Wayland tiling WM) plus its usual companions. home-manager writes
# ~/.config/sway/config from the `config` attrs below - edit them, run `hm`,
# and reload sway. Launch it from a tty with `sway`.
{
  wayland.windowManager.sway = {
    enable = true;
    config = rec {
      modifier = "Mod4"; # Super key
      terminal = "foot";
      menu = "wofi --show drun";

      # example: keybindings beyond the defaults
      keybindings = pkgs.lib.mkOptionDefault {
        "${modifier}+Return" = "exec ${terminal}";
        "${modifier}+d" = "exec ${menu}";
        "${modifier}+Shift+q" = "kill";
      };

      # bars, outputs, input { } etc. can be declared here too.
    };
  };

  # tools the WM leans on
  home.packages = with pkgs; [
    foot
    wofi
    waybar
    mako
    grim
    slurp
    wl-clipboard
    pamixer
    brightnessctl
    playerctl
  ];

  # NOTE (nvidia + intel laptop): the intel iGPU drives the built-in display
  # fine under sway. If you ever force the nvidia GPU and sway refuses to start,
  # launch it once with `sway --unsupported-gpu`.
}
