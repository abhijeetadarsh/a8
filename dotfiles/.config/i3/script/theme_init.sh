#!/usr/bin/env bash
#
# theme_init.sh - pick a wallpaper, derive the desktop palette from it, and
# reload everything that can be reloaded without a logout.
#
#   theme_init.sh --new             a new wallpaper from $WALLPAPER_SOURCE
#   theme_init.sh --my_collection   random image from ~/.wallpaper/my_collection
#   theme_init.sh --bing            fetch today's Bing image first
#   theme_init.sh --file <path>     use one specific image
#   theme_init.sh --waifu [tags]    fetch a new one from waifu.im
#   theme_init.sh --reload          put back the wallpaper already in use
#
# $WALLPAPER_SOURCE picks which of those --new means: my_collection (default),
# bing, or waifu. It is exported from ~/.xinitrc, so i3 and everything it
# starts inherit it. $mod+Shift+w is the only wallpaper key and it runs --new.
#
#   --no-wallpaper                  derive the palette but leave the desktop
#                                   background alone (fetch_wallpaper.sh has
#                                   already set it, possibly per monitor)
#
# i3 runs `--reload` at startup, so a reboot brings back the wallpaper you were
# actually using. Every other mode picks a *new* image, which is why none of
# them belongs in exec_always: booting would silently discard your wallpaper.
# $mod+Shift+w is the on-demand "give me a different one".

set -uo pipefail

ENGINE="$HOME/.config/polybar/shades/theme_engine/main.py"
CACHE="$HOME/.cache/theme"
STATE="$CACHE/wallpaper"

die() { printf 'theme_init: %s\n' "$*" >&2; exit 1; }

# fetch_wallpaper.sh can set a different image on each monitor. Re-running feh
# with one image here would flatten that, so it is skippable.
SET_WALLPAPER=1
ARGS=()
for a in "$@"; do
    if [[ "$a" == "--no-wallpaper" ]]; then SET_WALLPAPER=0; else ARGS+=("$a"); fi
done
set -- "${ARGS[@]:-}"

# --- 1. which wallpaper -----------------------------------------------------

pick_random() {
    # -L so symlinked wallpaper directories work too.
    find -L "$1" -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
           -o -iname '*.webp' -o -iname '*.bmp' \) 2>/dev/null | shuf -n 1
}

# --new is the one the keybinding uses. Resolve it here so the rest of the
# script only ever sees a concrete source, and an unusable $WALLPAPER_SOURCE
# says so instead of silently falling back to something you did not ask for.
if [[ "${1:-}" == "--new" ]]; then
    shift
    case "${WALLPAPER_SOURCE:-my_collection}" in
        my_collection|collection|local) set -- --my_collection "$@" ;;
        bing)                           set -- --bing "$@" ;;
        waifu|waifu.im)                 set -- --waifu "$@" ;;
        *) die "WALLPAPER_SOURCE=${WALLPAPER_SOURCE} is not one of: my_collection, bing, waifu" ;;
    esac
fi

# Default to --reload: a bare run should not change which wallpaper you have.
case "${1:---reload}" in
    --bing)
        shift
        # Same path as --waifu: fetches, stores, applies, then calls back in
        # here with --file. Errors are not swallowed - a failed download used
        # to look exactly like a working one.
        exec "$HOME/.config/i3/script/fetch_wallpaper.sh" --bing "$@"
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
    --waifu)
        shift
        # Fetches, stores, applies and then calls back in here with --file.
        exec "$HOME/.config/i3/script/fetch_wallpaper.sh" "$@"
        ;;
    --reload)
        # What i3 runs at every start. The recorded wallpaper may have been
        # pruned out of a library since, so fall back the same way
        # --my_collection does rather than coming up unthemed.
        WALLPAPER="$(cat "$STATE" 2>/dev/null)"
        if [[ -z "$WALLPAPER" || ! -f "$WALLPAPER" ]]; then
            WALLPAPER="$(pick_random "$HOME/.wallpaper/my_collection")"
            [[ -z "$WALLPAPER" ]] && WALLPAPER="$(pick_random "$HOME/.wallpaper")"
        fi
        ;;
    *)
        die "usage: $0 [--new | --reload | --my_collection | --bing | --waifu [tags] | --file <path>] [--no-wallpaper]"
        ;;
esac

# --- 2. generate the palette ------------------------------------------------

mkdir -p "$CACHE"

if [[ -n "${WALLPAPER:-}" && -f "$WALLPAPER" ]]; then
    python "$ENGINE" "$WALLPAPER" -o "$CACHE" || die "palette generation failed"
    printf '%s\n' "$WALLPAPER" > "$STATE"
    if (( SET_WALLPAPER )) && command -v feh >/dev/null; then
        feh --bg-fill "$WALLPAPER"
        # fetch_wallpaper.sh tracks which image is on which output separately,
        # and reads it back to leave other screens alone. One image just went
        # onto all of them, so say so - otherwise a later --monitor run would
        # restore a stale per-screen split nobody asked for.
        if command -v xrandr >/dev/null; then
            : > "$CACHE/wallpapers"
            xrandr --listmonitors 2>/dev/null | awk 'NR > 1 { print $NF }' |
                while read -r out; do
                    [[ -n "$out" ]] && printf '%s\t%s\n' "$out" "$WALLPAPER" >> "$CACHE/wallpapers"
                done
        fi
    fi
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

# GTK apps read gtk.css once, at startup. They do re-read it when the theme
# setting changes, though, so toggling the theme name off and back on is what
# makes an already-open Thunar repaint. The toggle is two settings changes in
# a row: GTK only reloads on an actual change, so setting it to the value it
# already has does nothing.
if command -v gsettings >/dev/null; then
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null
    gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita' 2>/dev/null
    gsettings set org.gnome.desktop.interface gtk-theme 'Adwaita-dark' 2>/dev/null
fi

# Firefox and Qt apps have no reload path at all - Firefox parses userChrome.css
# during startup and qt5ct's palette is read when the app builds its QPalette.
# Both pick the new colours up the next time they are launched.

# polybar cannot reload, only restart - launch.sh already kills the old one and
# starts one bar per connected monitor.
"$HOME/.config/polybar/shades/launch.sh" >/dev/null 2>&1

# i3 last: it re-reads colors.conf and repaints every border.
if command -v i3-msg >/dev/null; then
    i3-msg -q reload 2>/dev/null
fi

exit 0
