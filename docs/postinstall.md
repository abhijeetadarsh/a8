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
   to edit when you want to add something. `speech-dispatcher` and `espeak-ng`
   ride along with Firefox - they are what its "Listen" control and any site
   using the Web Speech API talk to, and without both there is no voice and no
   error to explain it. `mpv` is the video player, configured in
   [`dotfiles/.config/mpv/mpv.conf`](../dotfiles/.config/mpv/mpv.conf).
3. **AUR** - builds `jump-bin` and `i3lock-color` with makepkg directly; no
   AUR helper is installed (see below).
4. **Services** - NetworkManager, bluetooth, and the pipewire user services.
5. **Display power** - three root-owned files: `i915 enable_psr=0` (see
   [Black screen at idle](#black-screen-at-idle) below), full SysRq so a wedged
   session can still be shut down cleanly, and a 30s journal sync so a forced
   poweroff stops eating the logs that explain it. Rebuilds the initramfs only
   when the module option actually changed.
6. **Dotfiles** - `stow`s [`../dotfiles`](../dotfiles) into `$HOME`. Anything
   real already sitting at a target path is moved to
   `~/.dotfiles-backup-<timestamp>/` first, so nothing is silently destroyed.
7. **`~/.xprofile` and `~/.xinitrc`** - the session environment and the two
   ways into it. See below; a file either of them wrote is rewritten on a
   re-run, one you wrote yourself is left alone.
8. **Login screen** - LightDM plus the GTK greeter, configured and enabled, the
   directory the greeter reads its theme from, and a `display-setup-script` so
   the greeter arranges the monitors before it draws (see
   [The greeter's monitor layout](#the-greeters-monitor-layout)).
9. **Palette** - generates the desktop colour scheme from a wallpaper, so the
   first login lands on a themed desktop rather than an i3 config error.
   i3's other generated include, `monitors.conf`, gets an empty placeholder for
   the same reason: the script cannot work out the real monitor layout without
   a running X server, and `monitors.sh` rewrites it at every i3 start anyway.
10. **neovim plugins** - installs and pins them from
    [`lazy-lock.json`](../dotfiles/.config/nvim/lazy-lock.json) headlessly, and
    deletes clones that are no longer in `lua/plugins/`, so the plugin tree is
    built by this script rather than by whenever you first happen to open nvim.

## The greeter's monitor layout

**Symptom:** the login window ignores your monitor arrangement, and everything
snaps into place the moment you log in.

**Cause:** the greeter's X server is not your session's. `monitors.sh` is run
by i3, and at the login screen there is no i3 yet - so X arranges the outputs
however it likes, with no primary and no positions, and the login box lands
accordingly. Logging in starts i3, i3 runs `monitors.sh`, and the layout you
configured finally appears.

**Fix:** LightDM's `display-setup-script` runs as root on the greeter's
display before the greeter starts. `postinstall.sh` writes
`/etc/lightdm/lightdm.conf.d/10-monitor-layout.conf` pointing at
`/etc/lightdm/display-setup.sh`, which runs:

```sh
/usr/local/bin/i3-monitors --xrandr-only --order-file "$HOME/.config/i3/monitor-order"
```

Three details that are not incidental:

- **`--xrandr-only`** is a `monitors.sh` mode that arranges the screens and
  writes nothing. The normal path would create `monitors.conf` - as root, in
  whichever home it thinks it has.
- **`/usr/local/bin/i3-monitors` is a root-owned copy**, refreshed on every
  postinstall run. LightDM runs this as root, and pointing root at a script
  inside `$HOME` hands root to anything that can write there. Edit
  `dotfiles/.config/i3/script/monitors.sh` and re-run postinstall; the copy is
  the one place in this repo that does not update just by editing the file.
- **`--order-file` with an absolute path**, because root's `$HOME` is not
  yours. The layout file is read as data and parsed into xrandr arguments, and
  is never executed.

There is deliberately **no `active-monitor`** in the greeter config. Unset, the
greeter puts the login window on the primary output - which the script above
has just set - so it follows the layout on its own and still does the right
thing when you undock. Naming an output there would be a second place to keep
in sync, and wrong as soon as that monitor is unplugged.

Test it without rebooting - it is exactly what LightDM runs:

```sh
sudo DISPLAY=:0 XAUTHORITY=~/.Xauthority /etc/lightdm/display-setup.sh
```

## Black screen at idle

**Symptom:** leave the machine alone, come back to a black screen, and no key
or mouse movement brings it back - but the box is clearly still running, so the
only way out is holding the power button.

**Cause on this hardware:** Panel Self Refresh. The Ice Lake display controller
hands the panel off to refresh itself, and coming back out of that fails - the
kernel keeps running, it just never gets a picture again. The tell is that the
machine is *alive*: it answers SSH, Caps Lock still toggles its LED. A dead
kernel is a different bug (on this laptop, suspect nouveau's runtime power
management on the unused MX330 dGPU).

**Fix:** `postinstall.sh` writes `options i915 enable_psr=0` to
`/etc/modprobe.d/i915-psr.conf` and rebuilds the initramfs. That last part is
not optional - `i915` loads from the initramfs via the `kms` hook, long before
`/etc` exists, so the option only reaches it because mkinitcpio's `modconf`
hook copies `/etc/modprobe.d` into the image. **It takes effect on the next
boot, not immediately.** Confirm with:

```sh
cat /sys/module/i915/parameters/enable_psr   # 0 = off, -1 = kernel default
```

If you would rather keep half of it, `enable_psr=1` forces PSR1 and disables
PSR2, which is usually the guilty half. Edit the value in `do_power()` in
`postinstall.sh` rather than in `/etc`, so the next machine inherits it.

**Idle timings** are now stated in the i3 config rather than inherited from
X's defaults, which blank the screen and cut the panel's power in the same
instant:

```
exec_always --no-startup-id xset s 600 600 dpms 0 0 900
```

Lock at 10 minutes, panel off at 15. The gap means the locker is up and
visible before anything powers down, so a black screen at 12 minutes is a
fault rather than normal behaviour.

**If it happens again:** `Alt+SysRq+R E I S U B` now reboots cleanly (full
SysRq is enabled), instead of a power-button hold. Then read the tail of the
previous boot - with the 30s journal sync it survives:

```sh
journalctl -b -1 -p warning --no-pager | tail -40
```

## neovim

The config is deliberately small: **treesitter for syntax highlighting** and
the wallpaper-derived colourscheme, plus telescope, nvim-tree, lualine, a
splash screen and toggleterm. There is **no LSP** - no mason, no lspconfig, no
none-ls, no completion engine - so nothing downloads language servers behind
your back and there is nothing to configure per language.

Adding a plugin means dropping a file in
[`dotfiles/.config/nvim/lua/plugins/`](../dotfiles/.config/nvim/lua/plugins);
removing one means deleting that file and re-running this script, which cleans
the clone up. Commit `lazy-lock.json` after `:Lazy update` to keep other
machines on the same commits.

`nvim-treesitter` is pinned to its `master` branch on purpose. Upstream's
default branch is now `main`, a rewrite with a different API, and following it
would leave every buffer unhighlighted.

## Screen tearing

picom is the only thing in this stack that syncs to the vblank. The display is
driven by Xorg's `modesetting` driver, which on this xorg-server has no
`TearFree` option at all - the string is not in `modesetting_drv.so`, so an
`xorg.conf.d` snippet setting it is silently ignored. There is no second layer
to fall back on.

So tearing means one of two things:

- **picom is not syncing.** Check it:

  ```sh
  picom --config ~/.config/picom/picom.conf --log-level=info --log-file=/tmp/picom.log
  ```

  A working setup logs `Using vblank scheduler: present.` and lists the
  `SGI_swap_control` / `OML_sync_control` GLX extensions as present. `vsync`
  and `unredir-if-possible = false` are both set in
  [`picom.conf`](../dotfiles/.config/picom/picom.conf); the second one matters
  as much as the first, because an unredirected window scans out unsynced no
  matter what `vsync` says.

- **Something escaped the compositor.** Fullscreen video and games are the
  usual culprits. `mpv.conf` pins `vo=gpu` and `x11-bypass-compositor=no` so
  mpv stays composited even fullscreen; anything else that tears only in
  fullscreen is asking to bypass picom the same way.

## Two ways in, one environment

`startx` runs `~/.xinitrc`. LightDM does not read that file at all - it runs
`/etc/lightdm/Xsession`, which sources `~/.xprofile`, merges `~/.Xresources`
itself, and then execs whatever `/usr/share/xsessions/i3.desktop` says, which
is a bare `Exec=i3`.

So the session environment lives in **`~/.xprofile`**, and `.xinitrc` sources
it. Anything exported only from `.xinitrc` is silently missing under the
display manager: Qt apps come up unthemed, Java apps draw blank windows, and
`$mod+Shift+w` loses `WALLPAPER_SOURCE`.

`WALLPAPER_SOURCE` is the one line in the generated `.xprofile` you are meant
to edit, so a re-run reads the current value and keeps it rather than resetting
it to the default.

To go back to booting at a TTY:

```sh
sudo systemctl disable lightdm.service
```

`startx` keeps working either way.

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

### Includes in a symlinked config must be absolute

i3 resolves the config path with `realpath()` before handling `include`, so a
*relative* include inside a symlinked config is looked up next to the symlink's
**target** - `dotfiles/.config/i3/` - and never next to the symlink itself.
Every generated file is written to `~/.config/i3/`, so `include colors.conf`
found nothing. i3 does not treat a missing include as an error, so this failed
in complete silence: no config error, no message, just window colours and
workspace-to-monitor assignments that quietly never applied.

Both i3 includes are therefore written `include ~/.config/i3/<file>`.

kitty and rofi resolve their includes against the path as given, not the
resolved one, so `include current-theme.conf` and `@import "colors.rasi"` are
fine as they are. i3 is the only one that needs the absolute form.

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

## Network, from the bar

Click the network icon in the tray. `nm-applet` lists the wifi networks in
range, asks for a password when it needs one, and handles wired connections and
VPNs - no terminal and no `nmtui`.

There is deliberately no second network module on the bar. One briefly existed,
a rofi menu driven by `nmcli`, and it did the same job as the tray icon that was
already running: two ways to join a network, one of them a reimplementation of
the other. The tray is the one that comes with NetworkManager and handles the
cases a menu should not try to, so it is the one that stayed.

The example modules in `modules.ini` use `interface-type = wireless|wired`
rather than an interface name - `interface = wlp2s0` works on exactly one
machine.

## The system tray

`nm-applet` and `blueman-applet` are started by the i3 config, and both are
*only* a tray icon - that is their entire interface. There was no tray, so both
ran as background processes nobody could reach, and **bluetooth had no UI at
all**.

The tray is the `tray` module in `user_modules.ini`, and it goes on exactly one
bar. `_NET_SYSTEM_TRAY_S0` is a single X selection: with one polybar per
monitor, every instance asking for it would race and the losers would log an
error. So `launch.sh` starts `bar/main-tray` on the primary output and
`bar/main` everywhere else - the same bar, `inherit`ed, with the module added.

It has to be a separate bar section rather than an env-var in `modules-right`:
polybar does not expand `${env:...}` inside a module list, it takes the whole
token as a module name and disables it.

Nor the bar-level `tray-position` settings - polybar 3.7 deprecates those in
favour of the module and warns about every one it finds.

Applets that start before the bar still appear: they watch for the tray to show
up and dock when it does, so the startup order does not matter.

## Spiral tiling

New windows split the focused container along its **longer** axis, so each one
halves the largest free space and the layout spirals:

```
+-------------------+---------+
|                   |    2    |
|         1         +----+----+
|                   | 3  | 4  |
+-------------------+----+----+
```

i3 has no such layout. Its model is nested horizontal and vertical splits, and
a new window always splits the same way, which is what makes everything stack
down one axis. `autotiling` watches the focus and sets the split direction to
match the container's shape - wide splits vertically, tall splits horizontally.

It is in the official repos, so it is a package rather than a script in here,
and it runs from `exec_always` - not `exec` - because it has to come back after
an i3 restart or the layout quietly reverts to splitting one way forever.

`$mod+h`/`$mod+v` stay unbound, since the direction is chosen for you.
`$mod+e`, `$mod+s` and `$mod+w` still switch a container between split, stacked
and tabbed.

### The bar's menus

There is no launcher icon on the bar. `$mod+d` opens the same rofi launcher,
and an always-visible magnifier that does only that is clutter.

The power menu (the icon at the far right) and its confirmation dialog use the
same theme as that launcher - same border, same radius, same accent selection -
so the desktop has one menu style rather than three. Its **Lock** entry runs the
themed locker, the same screen `$mod+Ctrl+l` and `xss-lock` produce.

### Why the icon font is the "Propo" face

`font-1` is `CaskaydiaCove Nerd Font Propo`, not `CaskaydiaCove Nerd Font`.

The plain face draws its icons double-width, but polybar advances one cell for
them, so the left half of every icon was cut off - a speaker with no body, a
battery with no outline, a clock with no rim. The `Mono` face fixes the clipping
by squeezing icons into one cell, which makes them noticeably small. `Propo`
gives each icon its natural width, which is what the bar wants.

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

### There is no per-monitor DPI

`Xft.dpi` is a property of the display, not of an output. There is one value
and every app reads it, so two screens of different pixel density cannot both
be right. Per-monitor scaling is one of the things Wayland exists to fix.

`xrandr --scale` looks like a way around it - render an output at a multiple
of its resolution and let the GPU resample onto the panel - but it is not
worth the trouble here. It resamples rather than redraws, so text goes soft;
and `--right-of` ignores the transform, so a scaled screen silently overlaps
the next one by the difference. Set `Xft.dpi` to a value that is a reasonable
compromise across your screens instead, and adjust per-app font sizes.

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
