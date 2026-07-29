# Your dotfiles, the Nix way

**Yes - you can fully replace a traditional dotfiles repo with home-manager.**
Instead of a pile of raw config files plus a `stow`/symlink script, you declare
your config as data and home-manager generates the files and installs the
matching programs. One `home-manager switch` reproduces your whole user
environment on any machine, identically.

This repo uses the **native module** style: each program is configured through
its home-manager options (`programs.git`, `programs.neovim`,
`wayland.windowManager.sway`, ...). See the files under [`../nix/modules`](../nix/modules).

## The two ways to express a dotfile

### 1. Native modules (what this repo does)

```nix
programs.git = {
  enable = true;
  userName = "Abhijeet Adarsh";
  aliases.lg = "log --oneline --graph";
};
```

home-manager writes `~/.config/git/config` for you. Declarative, reproducible,
and you get option checking. Best for shell, git, WM, terminal, most tools.

### 2. Symlink a raw file (keep it verbatim)

When you have an existing config you don't want to rewrite (a big neovim setup,
say), keep the raw files in the repo and point home-manager at them:

```nix
# copy into the nix store (changes need a `switch`)
xdg.configFile."nvim".source = ./dotfiles/nvim;

# OR live-symlink so edits apply without re-switching:
xdg.configFile."nvim".source =
  config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/arch-nix-setup/nix/dotfiles/nvim";
```

You can mix both freely - native where it's clean, symlink where it isn't.

## Migrating your existing dotfiles repo

1. **Inventory** what's in it: shell rc, git config, WM config, editor, etc.
2. For each, pick a lane:
   - has a home-manager module and is simple -> rewrite as native (lane 1).
   - large/fiddly or you want it verbatim -> drop the raw files under
     `nix/dotfiles/` and symlink (lane 2).
3. Add a module file under `nix/modules/` (copy an existing one as a template)
   and `import` it from `nix/home.nix`.
4. `home-manager switch --flake ~/arch-nix-setup/nix#<user>` and verify.
5. Delete the old dotfiles/stow scripts once you're happy.

## Applying and iterating

```sh
# first time (home-manager not yet on PATH):
nix run home-manager/master -- switch --flake ~/arch-nix-setup/nix#<user>

# after that (aliased to `hm` in shell.nix):
home-manager switch --flake ~/arch-nix-setup/nix#<user>

# roll back if a change broke something:
home-manager generations          # list
/nix/store/...-home-manager-generation/activate   # activate an older one
```

## Handy references

- home-manager options search: <https://home-manager-options.extranix.com/>
- nixpkgs package search: <https://search.nixos.org/packages>
- home-manager manual: <https://nix-community.github.io/home-manager/>
