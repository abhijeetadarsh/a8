# arch-setup

A personal Arch Linux setup in two halves, matching the two genuinely different
jobs involved:

1. **`installer/archsetup.py`** — an interactive installer that lays down the
   **system layer** from the live ISO: partitions, filesystems, kernel, drivers,
   bootloader, users, networking. The part that is hard, risky, and done once.
2. **`installer/postinstall.sh`** — builds the **user layer** on the freshly
   booted system: X server, audio, the i3 desktop, apps, and the dotfiles in
   this repo. The part you keep tweaking.

> **Why split it?** Getting Arch onto a disk is fiddly and unforgiving — worth a
> careful interactive script. Installing packages and linking configs is neither;
> it is a package list and `stow`. Keeping them apart means you can re-run the
> second one forever without ever touching the first.

## Repository layout

```
arch-setup/
├── installer/
│   ├── archsetup.py          # single-file Arch system installer (run from the ISO)
│   └── postinstall.sh        # desktop + apps + dotfiles (run after first boot)
├── dotfiles/                 # the i3 rice, stowed into $HOME
│   ├── .bashrc  .Xresources  .gitconfig
│   └── .config/{i3,polybar,rofi,picom,alacritty,kitty,nvim,gtk-3.0,gtk-4.0}
├── examples/
│   └── answers.example.json  # a saved installer answer set (for --config)
├── docs/
│   ├── install.md            # step-by-step install from the ISO
│   └── postinstall.md        # what postinstall.sh does, and how stow works
├── LICENSE
└── README.md
```

### Why is the installer one file?

Deliberately. You run it from the Arch **live ISO**, where cloning a repo and
setting up a Python package is friction. `curl` one file, run it, done. The
*repository* is properly structured; the *installer* stays a single portable
script.

## Quick start

### 1. Install the base system (from the Arch ISO)

```sh
curl -LO https://raw.githubusercontent.com/<you>/arch-setup/main/installer/archsetup.py
python archsetup.py           # or --dry-run first to preview
```

Nothing is written to disk until you have read the summary and typed `INSTALL`.
Full walkthrough: [`docs/install.md`](docs/install.md).

You reboot into a text-mode Arch system with networking and nothing else.

### 2. Build the desktop (after the first boot)

```sh
nmtui                                       # connect to wifi
git clone https://github.com/<you>/arch-setup ~/arch-setup
~/arch-setup/installer/postinstall.sh
startx                                      # launch i3
```

That installs ~90 packages, enables the services, and stows the dotfiles.
Details: [`docs/postinstall.md`](docs/postinstall.md).

## How the dotfiles work

`postinstall.sh` uses GNU `stow` to symlink `dotfiles/` into `$HOME` —
`~/.config/i3` points at `~/arch-setup/dotfiles/.config/i3`, and so on.

Because the symlinks point at the **repo working tree**:

- Editing a config in `dotfiles/` changes your live setup immediately.
- Runtime writers keep working (lazy.nvim's lockfile, polybar's generated
  colorscheme).
- `git diff` shows exactly how your live config has drifted.

Anything already at a target path is moved to `~/.dotfiles-backup-<timestamp>/`
rather than overwritten.

## Customizing for your machine

The defaults target the author's setup (user `a8`, Intel+NVIDIA laptop, i3/X11).

- **Partitions, kernel, drivers** — answered interactively by the installer; a
  saved set lives in [`examples/answers.example.json`](examples/answers.example.json)
  (replay with `--config`).
- **Add/remove programs** — the grouped package arrays at the top of
  [`installer/postinstall.sh`](installer/postinstall.sh).
- **Any config** (i3 keybinds, polybar, git identity, nvim…) — edit the file
  directly under `dotfiles/`; it is your live config.
- **Repo location** — `postinstall.sh` finds itself, so `~/arch-setup` is a
  convention, not a requirement. But `stow` symlinks are absolute: if you move
  the repo after running it, re-run it.

## Requirements

- Installer: the Arch live ISO (ships Python). Nothing else.
- Post-install: a booted Arch system with networking, which the installer gives
  you.

## License

MIT — see [LICENSE](LICENSE).
