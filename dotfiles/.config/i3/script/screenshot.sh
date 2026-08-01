#!/usr/bin/env bash
#
# screenshot.sh - take one, and say so.
#
#   screenshot.sh full            the whole X screen, every monitor
#   screenshot.sh window          just the focused window
#   screenshot.sh region          drag a rectangle
#
#   --clip                        into the clipboard instead of a file
#
# The six Print bindings in the i3 config are these three modes with and
# without --clip.
#
# Why a script rather than three `maim` calls in the config:
#
#   - A screenshot is invisible. maim writes a file and exits; nothing appears
#     on screen, no window opens, and if it failed - no disk space, no active
#     window, xclip missing - i3 throws the error away and the key just looks
#     dead. Every outcome here ends in a notification, and the successful one
#     carries the shot itself as its icon, so you can see what you captured.
#
#   - The filename. The config built one with $(date), whose default format is
#     "Fri Aug  1 06:22:05 PM IST 2026": spaces, colons and a two-space column
#     for single-digit days, in a filename. Sorting a directory of those puts
#     April before August. An ISO-ish timestamp sorts chronologically and
#     needs no quoting anywhere.
#
#   - Cancelling a selection is not an error. maim exits non-zero when you
#     press Escape, exactly as it does when it genuinely fails, and the shell
#     one-liner could not tell those apart - so it either reported a failure
#     you caused on purpose or hid one you did not.

set -uo pipefail

NOTIFY="$HOME/.config/i3/script/notify.sh"

OUTDIR="${SCREENSHOT_DIR:-$HOME/Pictures/maim}"

# --clip keeps no file, but the notification still wants a thumbnail to show.
# One fixed path, overwritten every time, is what that costs: xclip reads the
# image into memory and serves the clipboard from there, so this copy exists
# only for dunst to draw.
CLIP_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/i3-screenshot-clipboard.png"

MODE=""
CLIP=0

while (( $# )); do
    case "$1" in
        full|screen)   MODE=full ;;
        window|active) MODE=window ;;
        region|select) MODE=region ;;
        --clip|-c)     CLIP=1 ;;
        --help|-h)
            awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
            exit 0 ;;
        *) printf 'screenshot: unknown argument: %s (try --help)\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

[[ -z "$MODE" ]] && { printf 'screenshot: pick a mode: full, window or region\n' >&2; exit 2; }

fail() {
    "$NOTIFY" -u critical -i dialog-error -t screenshot "Screenshot failed" "$1"
    exit 1
}

command -v maim >/dev/null || fail "maim is not installed"

# --- what to capture --------------------------------------------------------

MAIM=( maim )

case "$MODE" in
    full)
        ;;
    window)
        command -v xdotool >/dev/null || fail "xdotool is not installed"
        WID="$(xdotool getactivewindow 2>/dev/null)"
        # An empty window id would be passed to maim as no argument at all,
        # which quietly captures the whole screen instead of the window - a
        # silently wrong screenshot rather than a visible failure.
        [[ "$WID" =~ ^[0-9]+$ ]] || fail "no focused window to capture"
        MAIM+=( --window "$WID" )
        ;;
    region)
        # The selection rectangle gets the wallpaper's accent colour, like
        # every other thing you can see on this desktop. slop wants floats
        # from 0 to 1 and the palette is written as hex, so bash converts the
        # pairs and awk does the division.
        COLOUR="0.60,0.60,0.90"
        THEME_COLORS="${XDG_CACHE_HOME:-$HOME/.cache}/theme/colors.sh"
        if [[ -f "$THEME_COLORS" ]]; then
            # shellcheck source=/dev/null
            . "$THEME_COLORS" 2>/dev/null
            if [[ "${THEME_ACCENT:-}" =~ ^#([0-9a-fA-F]{6})$ ]]; then
                hex="${BASH_REMATCH[1]}"
                COLOUR="$(awk -v r="$(( 16#${hex:0:2} ))" \
                              -v g="$(( 16#${hex:2:2} ))" \
                              -v b="$(( 16#${hex:4:2} ))" \
                          'BEGIN { printf "%.3f,%.3f,%.3f", r/255, g/255, b/255 }')"
            fi
        fi
        MAIM+=( --select --bordersize 2 --color "$COLOUR" )
        ;;
esac

# --- take it ----------------------------------------------------------------
#
# Into a temporary file first. A cancelled or failed capture must not leave a
# 0-byte .png sitting in the library looking like a screenshot that came out
# black.

TMP="$(mktemp -t screenshot-XXXXXXXX.png)" || fail "could not create a temporary file"
trap 'rm -f "$TMP"' EXIT

ERR="$("${MAIM[@]}" "$TMP" 2>&1 >/dev/null)"
RC=$?

if (( RC != 0 )) || [[ ! -s "$TMP" ]]; then
    # Escape or right-click during a selection. Not a failure, and not
    # something to report: you know you cancelled it, you just did it.
    [[ "$ERR" == *ancel* ]] && exit 0
    fail "${ERR:-maim exited $RC}"
fi

SIZE="$(du -h "$TMP" | cut -f1)"

# --- clipboard --------------------------------------------------------------

if (( CLIP )); then
    command -v xclip >/dev/null || fail "xclip is not installed"

    # xclip forks and holds the selection for as long as it owns it, so it must
    # not be waited on and must not die with this script.
    xclip -selection clipboard -t image/png -i "$TMP" || fail "xclip could not take the clipboard"

    mkdir -p "$(dirname "$CLIP_CACHE")"
    cp -f "$TMP" "$CLIP_CACHE" 2>/dev/null

    "$NOTIFY" -u low -t screenshot -T 4000 -i "$CLIP_CACHE" \
        "Screenshot copied" "$SIZE in the clipboard"
    exit 0
fi

# --- or a file --------------------------------------------------------------

mkdir -p "$OUTDIR" || fail "could not create $OUTDIR"

STAMP="$(date +%Y-%m-%d_%H-%M-%S)"
FILE="$OUTDIR/$STAMP.png"
n=1
while [[ -e "$FILE" ]]; do            # two shots inside one second
    FILE="$OUTDIR/$STAMP-$n.png"
    n=$(( n + 1 ))
done

mv -f "$TMP" "$FILE" || fail "could not write $FILE"
trap - EXIT

# ~ rather than /home/you: the notification is 300px wide.
PRETTY="${OUTDIR/#$HOME/\~}"

# The icon is the screenshot, so the popup is a thumbnail of what was taken -
# which is the one thing that tells you the selection was the one you meant.
#
# The action makes the popup a button: middle click is `do_action` in dunstrc,
# and this is the only action offered, so it opens the shot. notify-send waits
# for the notification to close before printing what was picked, which is why
# this is the last thing the script does.
ACTION="$("$NOTIFY" -t screenshot -i "$FILE" -A default=Open \
    "Screenshot" "$(basename "$FILE")"$'\n'"$SIZE in $PRETTY")"

if [[ "$ACTION" == default ]] && command -v xdg-open >/dev/null; then
    setsid xdg-open "$FILE" >/dev/null 2>&1 &
fi

exit 0
