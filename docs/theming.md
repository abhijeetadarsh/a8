# Theming

One wallpaper decides the colour of the entire desktop. Change the wallpaper
and i3, polybar, rofi, kitty, dunst, GTK, neovim, ranger, the shell prompt and
the lock screen all change with it.

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
       └── ~/.config/gtk-{3.0,4.0}/gtk.css   Thunar, pavucontrol
```

`theme_init.sh` runs the generator and then reloads everything that can be
reloaded without a logout: `xrdb`, `SIGUSR1` to kitty, a dunst restart, a
polybar relaunch and `i3-msg reload`.

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

## Adding a program to the theme

1. Write a function in `writers.py` that takes the palette dict and a path.
2. Add it to `build_targets()` in `main.py` with a guard directory - the
   directory that must exist for that program to be considered installed.
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
