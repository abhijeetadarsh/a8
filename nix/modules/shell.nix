{ ... }:

# Interactive shell, prompt and fuzzy finder - all declared, no dotfiles to
# hand-edit. bash is the login shell the installer set up; here we make it nice.
{
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "ls -lah";
      la = "ls -A";
      update = "sudo pacman -Syu"; # system updates still go through pacman
      hm = "home-manager switch --flake ~/arch-nix-setup/nix#a8";
    };
    initExtra = ''
      # anything you'd normally drop in ~/.bashrc goes here
    '';
  };

  programs.starship.enable = true; # informative prompt; drop this line if unwanted
  programs.fzf.enable = true;
}
