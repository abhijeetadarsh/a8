# Building the desktop with `postinstall.sh`

`archsetup.py` leaves you with a bootable, text-mode Arch system.
`installer/postinstall.sh` turns that into the full i3 desktop.

Run it **as your normal user** (it calls `sudo` where it needs to):

```sh
git clone https://github.com/<you>/arch-setup ~/arch-setup
~/arch-setup/installer/postinstall.sh
```

Re-running it is the supported way to fix a half-finished install.

| flag | what it does |
| --- | --- |
| `--repair` | always show the package picker, even when nothing is missing |
| `--yes` | answer every prompt with the default (automation) |
| `--no-update` | skip the initial `pacman -Syu` |

## What it does, in order

1. **`pacman -Syu`** - refresh and update.
2. **Packages** - the X server, pipewire, i3, polybar, rofi, picom, kitty,
   ranger, neovim, fonts, and the Python stack the theme engine needs. The
   list is grouped by purpose at the top of the script; that is the one place
   to edit when you want to add something.
3. **AUR** - builds `jump-bin` and `i3lock-color` with makepkg directly; no
   AUR helper is installed (see below).
4. **Services** - NetworkManager, bluetooth, and the pipewire user services.
5. **Dotfiles** - `stow`s [`../dotfiles`](../dotfiles) into `$HOME`. Anything
   real already sitting at a target path is moved to
   `~/.dotfiles-backup-<timestamp>/` first, so nothing is silently destroyed.
6. **`~/.xinitrc`** - written so `startx` merges the X resources, points Qt at
   a platform theme so Qt apps follow the generated palette, and execs i3. An
   `.xinitrc` this script wrote is rewritten on a re-run; one you wrote
   yourself is left alone.
7. **Palette** - generates the desktop colour scheme from a wallpaper, so the
   first `startx` lands on a themed desktop rather than an i3 config error.
   i3's other generated include, `monitors.conf`, gets an empty placeholder for
   the same reason: the script cannot work out the real monitor layout without
   a running X server, and `monitors.sh` rewrites it at every i3 start anyway.

## Re-running: the package picker

The script never assumes its own past runs worked. It asks pacman what is
actually installed, and if anything is missing it shows a numbered list of
every package it manages:

```
  fonts
     58  ttf-fantasque-sans-mono      installed
     59  ttf-cascadia-code-nerd       installed
     62  papirus-icon-theme           missing

  6 of 71 packages are missing.

  What should I install?

    missing  just the missing ones
    1 5 12   those numbers - already-installed ones get reinstalled
    4-9      ranges work, and so do commas
    +name    a package that is not on this list at all
    all      reinstall everything
    none     skip this step
```

Picking a number that is already installed reinstalls it, which is how you
repair a package that installed but is broken. `+name` installs something that
is not in this repo's lists at all, without editing the script first.

After installing, it verifies each package against the database rather than
trusting pacman's exit code, and records anything that did not land in
`~/.local/state/arch-setup/failed-packages`. The next run tells you about it.

A system where more than 90% of the list is missing is treated as a fresh
install and everything goes in without the picker.

## There is no AUR helper

This setup needs exactly two AUR packages, so `postinstall.sh` builds them with
`makepkg` directly rather than installing a helper to do it:

```sh
git clone --depth 1 https://aur.archlinux.org/<pkg>.git
cd <pkg> && makepkg -si --needed
```

That avoids an entire class of failure. If you have ever seen

```
paru: error while loading shared libraries: libalpm.so.15
```

the cause is that AUR helpers link against pacman's C library. `paru-bin` is a
prebuilt binary; pacman 7.x bumped the soname to `libalpm.so.16`; the old
binary stopped starting. Every helper written in Rust or Go can hit this after
a pacman upgrade, and fixing it means recompiling the helper. `makepkg` ships
*with* pacman, so it cannot go out of sync with it.

It also means no Rust toolchain: `jump-bin` is used instead of `jump` because
it ships a prebuilt binary and needs no Go either. Everything else builds with
`base-devel`, which is installed anyway.

### Replacement packages

Both AUR packages here are **drop-in replacements**, not additions:

| AUR package | replaces | why |
| --- | --- | --- |
| `i3lock-color` | `i3lock` | same `i3lock` binary, plus the `--*-color` flags the lock script uses |
| `jump-bin` | `jump` | identical `jump` binary, just not compiled locally |

pacman will not swap those on its own - it asks *"Remove i3lock?"*, and under
`--noconfirm` the answer is No, so the build fails at the very last step. The
script reads `conflicts` out of the package's `.SRCINFO`, checks which are
actually installed, asks you once, and removes them before building. If the
build then fails, it reinstalls what it removed, so you are never left with
neither.

This is why `i3lock` is **not** in the repo package list: installing it and
`i3lock-color` together can only fail. `i3lock-color` provides the `i3lock`
binary, so `xss-lock ... -- i3lock --nofork` in the i3 config still works.

If you had a broken paru from an earlier setup, nothing here uses it now:

```sh
sudo pacman -Rns paru-bin paru
```

To install something from the AUR by hand later, the two commands at the top of
this section are the whole workflow.

## Why is `wayland` installed?

It is not a Wayland session, and removing it would take most of the desktop
with it. `wayland` is a **library package**, and these all link against it:

```
$ pactree -r wayland -d 1
wayland
├─dunst        ├─gtk3     ├─kitty   ├─mesa
├─gst-plugins  ├─gtk4     ├─libva   ├─rofi
└─qt6-base     └─vulkan-intel
```

Upstream builds GTK, Qt, kitty, rofi and dunst with both X11 and Wayland
backends in one binary; the Wayland code is simply never reached under X11. The
only Wayland-specific package this repo installs on purpose is `egl-wayland`,
pulled in by the NVIDIA driver sets in `archsetup.py`.

## How the dotfiles are linked

GNU stow is run with `--no-folding`, which matters:

- `~/.config/kitty` is a **real directory** containing a symlink to
  `kitty.conf` in the repo.
- Without `--no-folding`, stow would make `~/.config/kitty` itself one symlink
  into the repo - and the generated `current-theme.conf` would then be written
  *inside the git tree*.

Because the symlinks point at the repo working tree, editing a config in
`dotfiles/` changes your live setup immediately, and `git diff` shows exactly
how your live config has drifted.

The trade-off: adding a **new file** to `dotfiles/` needs a re-stow before it
appears in `$HOME`.

```sh
stow --dir=~/arch-setup --target=$HOME --restow --no-folding dotfiles
```

To unlink everything, swap `--restow` for `--delete`.

## Adding a program

1. Add the package to the right group at the top of `postinstall.sh`.
2. Drop its config under `dotfiles/` at the path it expects relative to `$HOME`.
3. Re-run the script, or just re-stow for a config-only addition.

## Things to check on the first run

- **Wallpapers** - the entire colour scheme is derived from one. If
  `~/.wallpaper/my_collection` is empty the script generates a placeholder
  gradient so the desktop still comes up themed; drop your own images in and
  press `$mod+Shift+w`.
- **NVIDIA** - if X will not start, check `/etc/X11/xorg.conf.d/` and
  `journalctl -b` for the driver.
- **Fonts** - boxes instead of icons means a font package did not install;
  check `fc-list | grep -i caskaydia`.

## Monitors

`i3/script/monitors.sh` detects what is connected, arranges it left to right,
and generates `~/.config/i3/monitors.conf` with the workspace assignments. i3
runs it at startup; `$mod+Shift+m` re-runs it after plugging a screen in.

| monitors | workspaces |
| --- | --- |
| 1 | all ten on it |
| 2 | 1-5 on the left, 6-10 on the right |
| 3+ | divided evenly, left to right |

### Position, primary and mode

These are three separate things, and setting one does not change the others:

| | what it means | where it comes from |
| --- | --- | --- |
| **position** | where a screen sits left to right | the order of the lines |
| **primary** | xrandr's `--primary` flag, one output | the `primary` flag |
| **mode** | resolution and refresh rate | the resolution/rate columns |

Position is what decides the workspace split - the number keys walk across the
desk in the order the screens physically sit. Marking a screen primary does
**not** move it and does **not** give it workspaces 1-5; it is what apps mean
when they ask for "the main screen".

Everything lives in one file, `~/.config/i3/monitor-order`. It ships with every
line commented out - which is why the desktop auto-detects until you edit it -
and the format is documented inside the file itself. One output per line, left
to right:

```
# output   resolution   rate   flags
HDMI-1     2560x1440    144    primary
eDP-1      1920x1080    60
```

Only the name is required. So the old bare list still works:

```sh
printf 'HDMI-1\neDP-1\n' > ~/.config/i3/monitor-order
~/.config/i3/script/monitors.sh          # apply now
```

That file says: HDMI-1 on the left running 2560x1440 at 144 Hz **and** primary,
eDP-1 to its right at 1920x1080/60. Workspaces 1-5 land on HDMI-1 because it is
leftmost, not because it is primary.

Resolution may carry the rate (`2560x1440@144`), and `-` or `auto` keeps the
screen's preferred resolution while still setting a rate or a flag:

```
eDP-1      -            47.99          # preferred resolution, 48 Hz
HDMI-1     auto         -       primary
```

### Trying it without committing

Every setting has a flag, and flags beat the file per setting - `--rate` alone
does not throw away the resolution the file gives for the same screen.

```sh
monitors.sh --modes                            # what each screen supports
monitors.sh --print                            # the plan, change nothing
monitors.sh --print --order "HDMI-1 eDP-1"     # preview a different order
monitors.sh --primary HDMI-1                   # apply once
monitors.sh --mode HDMI-1=2560x1440@144        # apply once
monitors.sh --rate eDP-1=60                    # apply once
```

`--modes` is where to start - it lists every resolution and rate per output, so
you can see what is actually available before writing it into the file.

These are **one-off**. `monitors.sh` runs with no arguments on every i3 start
and every `i3-msg reload` - and `theme_init.sh` reloads i3 - so a layout set
from the command line lasts until the next reload. The file is the durable
place to put one.

`--order` overrides the *ordering only*. The file is still read for each
screen's resolution, rate and `primary` flag, so putting a screen on the left
for a moment does not quietly drop everything else you configured.

Which is why `--print` shows two blocks - what it *would* apply, and what is
actually on screen right now:

```
would apply, from ~/.config/i3/monitor-order:
  left to right: eDP-1 HDMI-1
  primary:       eDP-1
...
on screen now:
  left to right: HDMI-1 eDP-1
  primary:       HDMI-1
...
These differ. What is on screen came from an earlier run;
the plan above is what the next i3 reload will put back.
```

They differ exactly when you have applied something one-off that the file does
not say. The plan is what wins at the next reload.

A mode a screen cannot do is **refused before xrandr sees it**, with the
supported list printed, and that screen falls back to its preferred mode:

```
monitors: HDMI-1 cannot do 3840x2160 - using its preferred mode
monitors:   it supports: 1920x1080 1680x1050 1280x1024 1440x900 1280x720 ...
```

This matters because xrandr fails *quietly*: hand it a mode the hardware does
not have and you get a dark screen and nothing on stdout. If the layout is
refused anyway, the whole thing is retried with preferred modes - a wrong
refresh rate beats a session with no working screen.

A rate given without a resolution is pinned to the screen's preferred
resolution before xrandr sees it, because `--output X --auto --rate 120` is
accepted, exits 0, and **changes nothing**: `--auto` picks the preferred mode
*and* its default rate, and ignores the `--rate` next to it. Only
`--mode WxH --rate R` actually switches the rate.

Outputs in the file that are not plugged in are skipped, and anything
connected but unlisted is appended on the right - so the same file works
docked and undocked. Delete it to go back to auto-detection.

### Why each workspace gets exactly one output

`monitors.conf` never writes a fallback list like
`workspace 1 output eDP-1 HDMI-1`. When an output is left with no workspace,
i3 fills it with the first workspace *assigned to that output*, and an
assignment matches if the output appears anywhere in its list - so the fallback
made workspace 1 a candidate for the external screen, which then showed 1, 2,
4 instead of 6. The file is regenerated on every start, so fallbacks buy
nothing anyway.

`workspace N output X` also only applies when a workspace is **created**.
Existing workspaces stay where they are across a reload, a restart, and across
plugging a monitor in, so `monitors.sh` moves them explicitly after writing the
file.
