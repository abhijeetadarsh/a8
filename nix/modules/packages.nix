{ pkgs, ... }:

# Plain packages that don't need their own configuration block.
# Anything you'd `pacman -S` for your user, put it here instead - then it is
# versioned and reproducible. (System packages like the kernel and GPU drivers
# still come from pacman; those are Arch's job, not home-manager's.)
{
  home.packages = with pkgs; [
    # cli tools
    ripgrep
    fd
    fzf
    jq
    tree
    htop
    btop
    unzip
    wget
    curl

    # apps
    firefox

    # fonts
    noto-fonts
    noto-fonts-emoji
    nerd-fonts.jetbrains-mono # if this errors on your channel, try `nerdfonts`
  ];
}
