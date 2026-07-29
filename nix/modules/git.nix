{ ... }:

# git config as data. Replace the name/email with yours (these are used as the
# author on every commit). home-manager writes ~/.config/git/config for you.
{
  programs.git = {
    enable = true;
    userName = "Abhijeet Adarsh";
    userEmail = "ad.abhijeetadarsh@gmail.com";

    aliases = {
      st = "status -sb";
      co = "checkout";
      lg = "log --oneline --graph --decorate --all";
    };

    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
    };
  };
}
