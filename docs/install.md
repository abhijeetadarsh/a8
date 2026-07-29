# Installing Arch with `archsetup.py`

The installer sets up **only the system layer** of Arch. Desktop, apps and
dotfiles come later, from Nix (see [dotfiles-with-nix.md](dotfiles-with-nix.md)).

## 1. Boot the Arch ISO

Write the official Arch ISO to a USB stick and boot it. You land in a root
shell in the live environment.

## 2. Get online

Wired: nothing to do. Wireless:

```sh
iwctl
    station wlan0 get-networks
    station wlan0 connect <SSID>
    exit
```

(The installer can also walk you through this.)

## 3. Get the installer onto the ISO

It is a single file on purpose - just fetch it:

```sh
curl -LO https://raw.githubusercontent.com/<you>/arch-nix-setup/main/installer/archsetup.py
```

...or copy it off a USB stick. No repo clone needed in the live environment.

## 4. Run it

```sh
python archsetup.py                # interactive, asks everything
python archsetup.py --dry-run      # walk the whole flow, touch nothing
python archsetup.py --config answers.json   # replay a previous run
```

Nothing is formatted until you have read the full summary and typed `INSTALL`.
Answers are saved to `/root/archsetup-answers.json` (never passwords) and copied
into the installed system at `/root/` so you can replay or audit later.

## 5. What it installs

Partitions/format/mount, `base` + kernel + firmware + microcode, locale, users
and sudo, bootloader, initramfs, swap, **GPU drivers**, NetworkManager, and
**Nix** (daemon + flakes, your user added to `nix-users`). It drops a minimal
starter `~/.config/home-manager` to get you into a desktop on first boot.

## 6. First boot

```sh
nmtui                                                     # wifi
nix run home-manager/master -- switch --flake ~/.config/home-manager#<user>
sway                                                      # start the desktop
```

Then graduate to the full config in this repo - see the README's
"After install" section.
