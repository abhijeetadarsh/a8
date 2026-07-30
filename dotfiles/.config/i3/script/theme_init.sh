#!/usr/bin/env bash
#
# theme_init.sh - pick a wallpaper, derive the desktop palette from it, and
# reload everything that can be reloaded without a logout.
#
#   theme_init.sh --my_collection   random image from ~/.wallpaper/my_collection
#   theme_init.sh --bing            fetch today's Bing image first
#   theme_init.sh --file <path>     use one specific image
#   theme_init.sh --reload          re-apply the current palette, no new colours
#
# i3 runs this at startup (exec_always) and $mod+Shift+w runs it on demand.

set -uo pipefail

ENGINE="$HOME/.config/polybar/shades/theme_engine/main.py"
CACHE="$HOME/.cache/theme"
STATE="$CACHE/wallpaper"

die() { printf 'theme_init: %s\n' "$*" >&2; exit 1; }

# --- 1. which wallpaper -----------------------------------------------------

pick_random() {
    # -L so symlinked wallpaper directories work too.
    find -L "$1" -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
           -o -iname '*.webp' -o -iname '*.bmp' \) 2>/dev/null | shuf -n 1
}

case "${1:---my_collection}" in
    --bing)
        "$HOME/.config/i3/script/download_wallpaper.sh" >/dev/null 2>&1
        WALLPAPER="$(pick_random "$HOME/.wallpaper/bing")"
        ;;
    --my_collection)
        WALLPAPER="$(pick_random "$HOME/.wallpaper/my_collection")"
        # An empty collection on first boot should not leave you staring at a
        # black screen with no bar, so fall back to anything else lying around.
        [[ -z "$WALLPAPER" ]] && WALLPAPER="$(pick_random "$HOME/.wallpaper")"
        ;;
    --file)
        WALLPAPER="${2:-}"
        [[ -f "$WALLPAPER" ]] || die "--file needs a readable image"
        ;;
    --reload)
        WALLPAPER="$(cat "$STATE" 2>/dev/null)"
        ;;
    *)
        die "usage: $0 [--my_collection | --bing | --file <path> | --reload]"
        ;;
esac

# --- 2. generate the palette ------------------------------------------------

mkdir -p "$CACHE"

if [[ -n "${WALLPAPER:-}" && -f "$WALLPAPER" ]]; then
    python "$ENGINE" "$WALLPAPER" -o "$CACHE" || die "palette generation failed"
    printf '%s\n' "$WALLPAPER" > "$STATE"
    command -v feh >/dev/null && feh --bg-fill "$WALLPAPER"
else
    # No wallpaper anywhere. Everything below still needs colours to exist, so
    # reuse the last palette if there is one, and otherwise say so plainly
    # rather than starting a desktop with no bar and no explanation.
    if [[ ! -f "$CACHE/colors.sh" ]]; then
        die "no wallpaper found and no previous palette - put images in ~/.wallpaper/my_collection, or run: $0 --bing"
    fi
    printf 'theme_init: no wallpaper found, re-applying the last palette\n' >&2
fi

# --- 3. reload everything ---------------------------------------------------
# Each step is best-effort. This runs during i3 startup, when half of these
# programs are not up yet, and one missing binary must not abort the rest.

# X resource database - xterm, i3lock, anything still reading xrdb.
if command -v xrdb >/dev/null; then
    [[ -f "$HOME/.Xresources" ]] && xrdb -merge "$HOME/.Xresources" 2>/dev/null
    [[ -f "$CACHE/colors.Xresources" ]] && xrdb -merge "$CACHE/colors.Xresources" 2>/dev/null
fi

# kitty re-reads its config on SIGUSR1, so open terminals recolour in place.
pkill -USR1 -x kitty 2>/dev/null

# dunst has to restart to pick up a changed drop-in.
if command -v dunst >/dev/null; then
    pkill -x dunst 2>/dev/null
    setsid dunst >/dev/null 2>&1 &
fi

# GTK reloads gtk.css when the colour scheme setting changes; nudge it.
if command -v gsettings >/dev/null; then
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null
fi

# polybar cannot reload, only restart - launch.sh already kills the old one.
"$HOME/.config/polybar/shades/launch.sh" >/dev/null 2>&1

# i3 last: it re-reads colors.conf and repaints every border.
if command -v i3-msg >/dev/null; then
    i3-msg -q reload 2>/dev/null
fi

exit 0
