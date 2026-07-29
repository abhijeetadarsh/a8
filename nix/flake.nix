{
  description = "a8's Arch Linux + home-manager user environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, home-manager, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      # Apply with:  home-manager switch --flake ~/arch-nix-setup/nix#a8
      # (rename "a8" below if your username differs, and keep it in sync
      #  with home.username in home.nix)
      homeConfigurations."a8" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [ ./home.nix ];
      };
    };
}
