# Theming

One wallpaper decides the colour of the entire desktop. Change the wallpaper
and i3, polybar, rofi, kitty, dunst, GTK, Qt, Firefox, Thunar, neovim, ranger,
the shell prompt and the lock screen all change with it.

```
$mod+Shift+w        new random wallpaper, re-theme everything
$mod+Ctrl+Shift+w   fetch today's Bing image and theme from that
```

## The pipeline

```
  wallpaper.jpg
       │
       ▼
  theme_engine/main.py          KMeans -> 8 dominant colours
       │
       ▼
  theme_engine/palette.py       clusters -> a readable palette
       │                        (this is where contrast is enforced)
       ▼
  theme_engine/writers.py       one writer per program
       │
       ├── ~/.cache/theme/colors.sh          shell scripts, i3lock
       ├── ~/.cache/theme/colors.json        debugging
       ├── ~/.cache/theme/colors.Xresources  xrdb
       ├── ~/.cache/theme/nvim.lua           neovim colourscheme
       ├── ~/.cache/theme/starship.toml      the prompt
       ├── ~/.config/i3/colors.conf          client.* + $accent
       ├── ~/.config/polybar/.../color/out.ini    the bar
       ├── ~/.config/polybar/.../color/out.rasi   the bar's rofi menus
       ├── ~/.config/rofi/colors.rasi        launcher
       ├── ~/.config/kitty/current-theme.conf     16 ANSI colours
       ├── ~/.config/dunst/dunstrc.d/99-theme.conf  notifications
       ├── ~/.config/gtk-{3.0,4.0}/gtk.css   Thunar, pavucontrol, GTK apps
       ├── ~/.gtkrc-2.0                      the GTK2 holdouts
       ├── ~/.config/qt{5,6}ct/...           Qt apps, if qt5ct/qt6ct is installed
       └── ~/.mozilla/firefox/<profile>/     Firefox, one set per profile
             ├── chrome/userChrome.css       the browser UI
             ├── chrome/userContent.css      the about: pages
             └── user.js                     the pref that enables the two above
```

`theme_init.sh` runs the generator and then reloads everything that can be
reloaded without a logout: `xrdb`, `SIGUSR1` to kitty, a dunst restart, a GTK
theme-name toggle, a polybar relaunch and `i3-msg reload`.

**All of these outputs are generated.** None of them is in git, and editing one
by hand lasts until the next wallpaper change.

## Why the colours are readable

A naive "use the dominant colours from the image" scheme gives you grey text on
a grey bar the first time you use a foggy photo. So the wallpaper only decides
**hue**; `palette.py` decides **lightness**, and every foreground colour is
pushed away from its background until it clears a WCAG contrast ratio:

| role | ratio | why |
| --- | --- | --- |
| `text` | 7.0 | AAA - this is body text in the terminal and the editor |
| `subtext`, `accent`, ANSI normal | 4.5 | AA body text |
| `muted`, ANSI bright | 3.0 | UI chrome and emphasis, not paragraphs |

The check runs on the 8-bit value that actually gets written to the config
file, not the float behind it, because rounding `#f8a562` is enough to drop a
colour just under its target.

The 16 ANSI slots are anchored to canonical hues and may only be pulled 12°
toward the wallpaper's dominant hue. A terminal red has to look like a red -
`git diff` and every TUI on the system depend on it.

## Toolkits, not just programs

Most of the desktop is one program per config file. The application toolkits
are not, and they are what makes the theme reach programs this repo has never
heard of.

**GTK3 / GTK4.** Adwaita-dark does the widget drawing and the generated
`gtk.css` redefines the colours it draws with, so Thunar, pavucontrol, the file
chooser and every other GTK app follow along. Adwaita hardcodes a few things
instead of naming them - Thunar's sidebar and path bar, tree view headers,
scrollbars - so `gtk.css` also carries explicit rules for those.

**GTK2.** `~/.gtkrc-2.0`. GTK2 has no cascade: one style block applied to
`GtkWidget` is the entire theme. Written unconditionally, because GTK2 apps
have no config directory to detect them by and the file is small.

**Qt.** Qt does not read GTK's colours on its own; a platform theme plugin
bridges the two, selected by `QT_QPA_PLATFORMTHEME` in `~/.xinitrc`:

| plugin | when | how it gets the colours |
| --- | --- | --- |
| `qt6ct` / `qt5ct` | installed | the engine writes them an exact palette |
| `gtk3` | otherwise | Qt reads the generated GTK theme |

The fallback is the default, and it is why neither qt5ct nor qt6ct is in the
package list: the colours are already there in `gtk.css`.

**Firefox** gets `userChrome.css` (tabs, toolbar, menus, sidebar, find bar),
`userContent.css` (the `about:` pages) and the `user.js` pref that makes
Firefox read either of them - written into every profile in `profiles.ini`.
The CSS drives Firefox's own `--lwt-*` and toolbar variables rather than
restyling individual widgets, which is what keeps it working across releases.
Websites are deliberately left alone; only `ui.systemUsesDarkTheme` is set, so
sites that have a dark mode use it.

## What repaints immediately, and what does not

`theme_init.sh` reloads what can be reloaded. The rest is a matter of how the
program reads its config, not something the script can work around:

| | when the new palette lands |
| --- | --- |
| i3, polybar, rofi, dunst, kitty, xrdb | immediately |
| GTK apps | immediately - the `gtk-theme` toggle in `theme_init.sh` forces a re-read of `gtk.css` |
| Qt apps | next launch |
| Firefox | next launch - `userChrome.css` is parsed during startup |
| neovim | `:ThemeReload`, or next launch |

A Firefox profile that does not exist yet cannot be themed, so the very first
run after installing skips it. The next `theme_init.sh` - which i3 runs at
login - picks it up.

## Adding a program to the theme

1. Write a function in `writers.py` that takes the palette dict and a path.
2. Add it to `build_targets()` in `main.py` with a guard - the directory that
   must exist for that program to count as installed, or a callable returning
   whether to write, for programs like qt5ct that have no config directory
   until they are first run. `None` means always write.
3. If the program reloads at runtime, add that to `theme_init.sh`.

The palette dict has surfaces (`base`, `mantle`, `crust`, `surface0..2`,
`overlay0..1`), text (`text`, `subtext`, `muted`), `accent` / `accent_dim`, the
16 ANSI names, and semantic aliases (`urgent`, `warning`, `success`, `info`,
`selection`, `border_active`, `cursor`). Reach for the semantic names.

To see a palette without applying it:

```sh
python ~/.config/polybar/shades/theme_engine/main.py some.jpg --print
```

## Programs that theme themselves

**ranger** cannot take hex colours - it draws with the terminal's 16 ANSI
slots. Since kitty's 16 colours are regenerated from the wallpaper, the
`wallpaper` colourscheme in `dotfiles/.config/ranger/colorschemes/` is written
purely in ANSI terms and follows along for free, with no generated file.

**neovim** loads `~/.cache/theme/nvim.lua` if it exists and falls back to
tokyonight if it does not - which is what happens on a fresh clone before the
first `theme_init.sh` run. `:ThemeReload` re-applies it in a running nvim.

## Light mode

The engine can build a light palette (`--light`), and all the contrast logic
works in both directions. Nothing is wired to a toggle yet; `theme_init.sh`
always asks for dark.

## Fetching wallpapers from waifu.im

`i3/script/fetch_wallpaper.sh` pulls a wallpaper from the waifu.im API, sets it
with `feh`, and re-themes the desktop from it.

```sh
fetch_wallpaper.sh                  # random landscape waifu on every monitor
fetch_wallpaper.sh maid             # extra tags, AND logic
fetch_wallpaper.sh --per-monitor    # a different image on each screen
fetch_wallpaper.sh --monitor HDMI-1 # just that one, others left alone
fetch_wallpaper.sh --offline        # skip the network entirely
DEBUG=1 fetch_wallpaper.sh          # show the API call and what came back
```

`$mod+Ctrl+w` runs it; `$mod+Ctrl+Shift+p` runs it per monitor.

### The library is the offline fallback

Downloads go to `~/.wallpaper/waifu` and stay there. With no network - or a
captive portal, or an API error - the script picks a random image already in
that directory instead of failing, so a laptop that boots offline still comes
up with a wallpaper and a matching palette.

`curl --max-time` bounds both the API call and the download, so an unreachable
network delays i3 startup by seconds rather than hanging it.

### The 50 MB cap

The directory is capped at 50 MB (`WAIFU_MAX_MB` to change it, `WAIFU_DIR` to
move it). The new image is always stored; **older ones are deleted to make room
for it**, oldest first by mtime, until the directory fits. The image that was
just downloaded and applied is protected from that sweep, so it can never be
evicted to make space for itself.

An image whose `byteSize` alone exceeds the cap is skipped before downloading -
storing it would mean deleting the entire library for one file.

### Per-monitor state

Which image is on which output is tracked in `~/.cache/theme/wallpapers`, one
`output<TAB>path` line each. `feh` takes one image per monitor in Xinerama
order, so `--monitor` can change a single screen without disturbing the others.

The palette is always derived from the image on the **first** monitor, since
there is only one desktop colour scheme.
