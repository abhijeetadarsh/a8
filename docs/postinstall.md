# Building the desktop with `postinstall.sh`

`archsetup.py` leaves you with a bootable, text-mode Arch system.
`installer/postinstall.sh` turns that into the full i3 desktop.

Run it **as your normal user** (it calls `sudo` where it needs to):

```sh
git clone https://github.com/<you>/arch-setup ~/arch-setup
~/arch-setup/installer/postinstall.sh
```

It is safe to re-run - `pacman --needed` skips what is installed and
`stow --restow` re-links what is already linked.

## What it does, in order

1. **`pacman -Syu`** - refresh and update.
2. **Repo packages** - the X server, pipewire, i3, polybar, rofi, picom, the
   terminals, neovim, fonts, and the Python stack polybar's theme engine needs.
   The list is grouped by purpose at the top of the script; that is the one
   place to edit when you want to add something.
3. **AUR** - builds `paru` if missing, then installs `jump` (the `j` command in
   `.bashrc`) and `i3lock-color` (used by the lock scripts).
4. **Services** - enables NetworkManager, bluetooth, and the pipewire user
   services.
5. **Dotfiles** - `stow`s [`../dotfiles`](../dotfiles) into `$HOME`. Anything
   real already sitting at a target path is moved to
   `~/.dotfiles-backup-<timestamp>/` first, so nothing is silently destroyed.
6. **`~/.xinitrc`** - written so `startx` merges `.Xresources` and execs i3.
   An existing non-symlink `.xinitrc` is left alone.
7. **Wallpapers** - creates `~/.wallpaper/{my_collection,bing}` and warns if
   they are empty, because the i3 config runs `theme_init.sh` at startup and
   that script needs a wallpaper to derive the polybar colorscheme from.

## How the dotfiles are linked

GNU stow makes `~/.config/i3` a symlink to `~/arch-setup/dotfiles/.config/i3`,
and so on for each program. Because the symlinks point at the **repo working
tree**:

- Editing a config in `dotfiles/` changes your live setup immediately. No
  re-run, no rebuild.
- Runtime writers keep working - `lazy.nvim` updating its lockfile, the polybar
  theme engine writing `~/.config/polybar/shades/color/`.
- `git diff` in the repo shows exactly how your live config has drifted.

To unlink everything:

```sh
stow --dir=~/arch-setup --target=$HOME --delete dotfiles
```

## Adding a program

1. Add the package to the right group at the top of `postinstall.sh`.
2. Drop its config under `dotfiles/` at the path it expects relative to `$HOME`.
3. Re-run the script (or just `stow --dir=... --restow dotfiles` for a
   config-only addition).

## Things to check on the first run

- **Wallpapers** - i3 starts `theme_init.sh --my_collection`. With an empty
  `~/.wallpaper/my_collection` you get no wallpaper and no polybar. Either put
  images there or switch the line in `dotfiles/.config/i3/config` to `--bing`.
- **NVIDIA** - if X will not start, check
  `/etc/X11/xorg.conf.d/` and `journalctl -b` for the driver. The Intel iGPU
  normally drives the built-in display fine.
- **Fonts** - the i3 config and polybar use Fantasque Sans Mono plus Nerd Font
  glyphs. Boxes instead of icons means a font package did not install; check
  `fc-list | grep -i caskaydia`.
