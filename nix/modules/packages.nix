{ pkgs, ... }:

# Every binary your i3 dotfiles invoke, installed into your user profile so the
# configs under ../dotfiles work verbatim. System-level pieces (kernel, GPU
# drivers, the X server, audio daemon) are NOT here - see the notes at the
# bottom; those stay with pacman because home-manager can't own them on Arch.
{
  home.packages = with pkgs; [
    # --- i3 / X11 window manager stack --------------------------------------
    i3                    # the WM itself (i3-msg, i3-nagbar, i3-config-wizard)
    i3status              # bar status source (config refreshes it via SIGUSR1)
    i3lock                # xss-lock uses this; scripts calling i3lock-color need i3lock-color instead
    xss-lock              # lock on suspend
    dex                   # XDG autostart (exec dex --autostart)
    picom                 # compositor (screen-tearing fix)
    polybar               # the actual bar
    rofi                  # launcher (rofi -show drun)
    feh                   # wallpaper setter
    networkmanagerapplet  # nm-applet tray icon

    # --- screenshots / clipboard (bound to Print keys) ----------------------
    maim
    xdotool
    xclip

    # --- X utilities the session needs --------------------------------------
    xorg.xrandr
    xorg.xset
    xorg.xsetroot
    xorg.setxkbmap
    xorg.xrdb             # .Xresources is merged by ~/.xinitrc

    # --- terminals ----------------------------------------------------------
    kitty                 # $mod+Return terminal
    alacritty             # also configured in your dotfiles

    # --- shell environment (.bashrc) ----------------------------------------
    starship              # prompt (your .bashrc runs `starship init bash`)
    jump                  # the `j` autojump command in .bashrc
    exa                   # your .bashrc aliases `ls` to `exa`
    #                       NOTE: exa is unmaintained and may be dropped from
    #                       nixpkgs. If this fails to build, use `eza` here and
    #                       change the alias in dotfiles/.bashrc to `eza`.

    # --- editors ------------------------------------------------------------
    neovim                # your lazy.nvim config lives in dotfiles/.config/nvim
    vim                   # .vimrc + .vim/plugged (vim-plug) setup
    gcc                   # nvim-treesitter compiles parsers
    ripgrep               # telescope / grep
    fd
    fzf

    # --- polybar theme-engine (dotfiles/.config/polybar/theme_engine) -------
    # Heavy, and only needed if you use theme_init.sh's wallpaper->colors step.
    # Comment this whole block out if you don't want the ~1GB of python deps.
    (python3.withPackages (ps: with ps; [
      numpy
      scikit-learn
      opencv4          # provides cv2
      matplotlib
    ]))

    # --- misc shell helpers the scripts call --------------------------------
    psmisc                # killall (polybar launch.sh, i3status refresh)
    procps                # pgrep

    # --- fonts --------------------------------------------------------------
    fantasque-sans-mono          # i3 title/bar font
    nerd-fonts.caskaydia-cove    # the commented alt font + workspace glyphs
    noto-fonts
    noto-fonts-emoji
  ];

  # ==========================================================================
  # NOT installed here (must come from pacman - they are system, not user):
  #   xorg-server xorg-xinit   -> the X server. Running an X server out of the
  #                               nix store on Arch is fiddly; install these
  #                               from pacman and i3 (from nix) runs on top.
  #   pipewire / pipewire-pulse (or pulseaudio) -> so `pactl` volume keys work.
  #   the GPU driver -> already handled by the installer (archsetup.py).
  # ==========================================================================
}
