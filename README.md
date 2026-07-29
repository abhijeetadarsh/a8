# arch-nix-setup

A personal, reproducible **Arch Linux** setup in two clean halves:

1. **`installer/archsetup.py`** — an interactive installer that lays down the
   **system layer** of Arch (partitions, kernel, drivers, bootloader, users,
   networking, and Nix itself).
2. **`nix/`** — a **home-manager** configuration that declares the **user
   layer** (desktop/WM, apps, dotfiles) as data. This is a dotfiles repo,
   done the Nix way.

> **The idea:** Arch owns the system, Nix owns the user. On plain Arch (not
> NixOS), home-manager can reproducibly manage your packages, WM and dotfiles,
> but *not* kernel-level things (drivers, display manager, system services) —
> so those stay with the installer, and everything user-facing moves to Nix.

## Repository layout

```
arch-nix-setup/
├── installer/
│   └── archsetup.py          # single-file Arch system installer (run from the ISO)
├── nix/                      # your user environment / dotfiles as home-manager
│   ├── flake.nix             # entry point:  #<username>
│   ├── home.nix              # imports the modules below
│   └── modules/
│       ├── packages.nix      # plain user packages
│       ├── shell.nix         # bash + prompt + fzf
│       ├── git.nix           # git identity & aliases
│       ├── neovim.nix        # editor config
│       └── sway.nix          # Wayland WM + companions
├── examples/
│   └── answers.example.json  # a saved installer answer set (for --config)
├── docs/
│   ├── install.md            # step-by-step install from the ISO
│   ├── dotfiles-with-nix.md  # replacing a dotfiles repo with home-manager
│   └── manual-install-notes.sh
├── LICENSE
└── README.md
```

### Why is the installer one file?

Deliberately. You run it from the Arch **live ISO**, where cloning a repo and
setting up a Python package is friction. `curl` one file, run it, done. The
*repository* is properly structured; the *installer* stays a single portable
script (a common pattern for bootstrap tools). The Nix side, which you edit and
live with, is split into real modules.

## Quick start

### 1. Install the base system (from the Arch ISO)

```sh
curl -LO https://raw.githubusercontent.com/<you>/arch-nix-setup/main/installer/archsetup.py
python archsetup.py           # or --dry-run first to preview
```

Full walkthrough: [`docs/install.md`](docs/install.md).

### 2. First boot — bootstrap your user environment

```sh
nmtui                                                     # connect to wifi
nix run home-manager/master -- switch --flake ~/.config/home-manager#<user>
sway                                                      # start the desktop
```

The installer seeds a minimal `~/.config/home-manager` so this works out of the
box.

### 3. Graduate to this repo's config

```sh
git clone https://github.com/<you>/arch-nix-setup ~/arch-nix-setup
home-manager switch --flake ~/arch-nix-setup/nix#<user>   # aliased to `hm`
```

Now `nix/` is your source of truth. Edit a module, run `hm`, done.

## Managing your dotfiles

Everything under `nix/modules/` is a dotfile expressed declaratively. Add a
package, tweak a keybinding, change your git aliases — edit the module and
`home-manager switch`. To migrate an existing dotfiles repo (native rewrite vs.
verbatim symlink), see [`docs/dotfiles-with-nix.md`](docs/dotfiles-with-nix.md).

## Customizing for your machine

The defaults target the author's setup (user `a8`, Intel+NVIDIA laptop, sway).
Change:

- **Username** — `home.username`/`homeDirectory` in `nix/home.nix` and the
  `homeConfigurations."a8"` key in `nix/flake.nix` (keep them in sync).
- **Git identity** — `nix/modules/git.nix`.
- **Packages / WM** — `nix/modules/packages.nix`, `nix/modules/sway.nix`.
- **Partitions, kernel, drivers** — answered interactively by the installer;
  a saved set lives in `examples/answers.example.json` (replay with `--config`).

## Requirements

- Installer: the Arch live ISO (ships Python). Nothing else.
- Nix side: `nix` with flakes enabled — the installer sets this up for you.

## License

MIT — see [LICENSE](LICENSE).
