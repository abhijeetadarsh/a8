# Installing Arch with `archsetup.py`

The installer sets up **only the system layer** of Arch. The desktop, apps and
dotfiles come afterwards, from [`postinstall.sh`](postinstall.md).

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
curl -LO https://raw.githubusercontent.com/<you>/arch-setup/main/installer/archsetup.py
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
and sudo, bootloader, initramfs, swap, **GPU drivers**, and NetworkManager -
plus `git` and `curl` so you can fetch this repo on first boot.

It deliberately installs **no** desktop, display server, audio stack or apps.
You reboot into a working text-mode Arch system and nothing more. That keeps the
risky, hard-to-redo part (disks and boot) separate from the part you will tweak
for years (your desktop).

## 6. First boot

```sh
nmtui                                       # connect to wifi
git clone https://github.com/<you>/arch-setup ~/arch-setup
~/arch-setup/installer/postinstall.sh       # builds the whole desktop
startx                                      # launch i3
```

See [`postinstall.md`](postinstall.md) for what that second script does.
