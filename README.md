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
│       ├── packages.nix      # every binary the dotfiles invoke
│       └── dotfiles.nix      # your configs, symlinked verbatim (see below)
├── nix/dotfiles/             # your actual i3 dotfiles, kept as-is
│   └── .config/{i3,polybar,rofi,picom,alacritty,kitty,nvim,...}
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

### 2. First boot — get online and clone this repo

```sh
nmtui                                              # connect to wifi
git clone https://github.com/<you>/arch-nix-setup ~/arch-nix-setup
```

The repo **must** live at `~/arch-nix-setup` — the dotfiles are symlinked from
there (see "How the dotfiles work" below). Adjust `repo` in
`nix/modules/dotfiles.nix` if you put it elsewhere.

### 3. Install the two system pieces Nix can't own, then apply

The user environment is an **i3 (X11)** rice. i3, polybar, rofi and all your
configs come from Nix, but the X server and the audio daemon are system
services — install those from pacman:

```sh
sudo pacman -S xorg-server xorg-xinit pipewire pipewire-pulse wireplumber
```

Then build your whole user environment from this repo:

```sh
nix run home-manager/master -- switch --flake ~/arch-nix-setup/nix#a8
startx                                             # launches i3 via ~/.xinitrc
```

After the first run, re-apply changes with:

```sh
home-manager switch --flake ~/arch-nix-setup/nix#a8
```

> At **install** time you can pick "none" for the starter WM (the installer's
> sway/hyprland seed is only a fallback) — your real setup is this repo.

## How the dotfiles work

This is your existing i3 dotfiles kept **exactly as they were**, not rewritten.
`nix/modules/dotfiles.nix` uses home-manager's `mkOutOfStoreSymlink` to symlink
`~/.config/i3`, `~/.config/polybar`, `~/.bashrc`, etc. straight to the live
files in `nix/dotfiles/`. Because the symlinks point at the **repo working tree**
(not a read-only nix-store copy):

- Your runtime writers keep working — polybar's `theme_engine` generating
  `~/.config/polybar/shades`, `lazy.nvim` writing its lockfile, `vim-plug`
  populating `~/.vim/plugged`.
- Editing a config in `nix/dotfiles/` changes your live setup immediately —
  no `home-manager switch` needed for a config-only edit (run it only after
  changing a `.nix` file, e.g. adding a package).

`nix/modules/packages.nix` installs every program those configs call (i3,
polybar, rofi, picom, feh, maim, kitty, starship, neovim, fonts, …). Migration
background (native modules vs. verbatim symlinks) is in
[`docs/dotfiles-with-nix.md`](docs/dotfiles-with-nix.md).

### Things to check on first apply

- **`exa`** — your `.bashrc` aliases `ls` to `exa`, which is unmaintained and
  may be gone from nixpkgs. If the build fails on it, switch `exa` → `eza` in
  `nix/modules/packages.nix` and edit the alias in `nix/dotfiles/.bashrc`.
- **Theme engine** — `packages.nix` pulls a Python with numpy/opencv/sklearn
  (~1 GB) for `polybar/theme_engine`. Comment that block out if you don't use
  the wallpaper→colors feature.
- **Fonts** — uses `nerd-fonts.caskaydia-cove`; on older nixpkgs the attribute
  was `nerdfonts`. Adjust if it doesn't resolve.

## Customizing for your machine

The defaults target the author's setup (user `a8`, Intel+NVIDIA laptop, i3/X11).
Change:

- **Username** — `home.username`/`homeDirectory` in `nix/home.nix` and the
  `homeConfigurations."a8"` key in `nix/flake.nix` (keep them in sync).
- **Any config** (i3 keybinds, polybar, git identity, nvim…) — edit the file
  directly under `nix/dotfiles/`; it's your live config.
- **Add/remove programs** — `nix/modules/packages.nix`, then `home-manager switch`.
- **Repo location** — if not `~/arch-nix-setup`, update `repo` in
  `nix/modules/dotfiles.nix`.
- **Partitions, kernel, drivers** — answered interactively by the installer;
  a saved set lives in `examples/answers.example.json` (replay with `--config`).

## Requirements

- Installer: the Arch live ISO (ships Python). Nothing else.
- Nix side: `nix` with flakes enabled — the installer sets this up for you.

## License

MIT — see [LICENSE](LICENSE).
