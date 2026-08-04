#!/usr/bin/env bash
#
# app.sh - open a settings window, or raise the one already open.
#
#   app.sh CLASS COMMAND [ARG...]
#
# What the bar's hardware buttons go through: the camera one (camera.sh) and
# the two audio ones (volume.sh). Not meant to be called by hand.
#
# Why "or raise" rather than just running the thing:
#
#   A bar button gets clicked twice. Usually by someone who cannot see that it
#   worked the first time, because the window opened on a workspace they are
#   not looking at - which is the normal case, since i3 puts a new window
#   wherever you happen to be and the bar is on every screen. Neither
#   pavucontrol nor guvcview declines a second instance, and two mixers
#   fighting over one sink is worse than no mixer: they show each other's
#   changes a moment late, so a slider you move jumps back under your cursor.
#
# The lookup goes through i3's tree rather than xdotool, which can also find
# the window but cannot switch to the workspace it is on. A raise that leaves
# the window where you cannot see it is indistinguishable from nothing
# happening, which is the bug this is here to prevent in the first place.
#
# CLASS is matched case-insensitively. An app's WM_CLASS capitalisation is its
# own business - pavucontrol is lowercase in both fields, most GTK apps
# capitalise the second - and guessing wrong fails silently, by opening a
# second window, which is exactly the failure being avoided.

set -uo pipefail

NOTIFY="$HOME/.config/i3/script/notify.sh"

(( $# >= 2 )) || {
    printf 'app: usage: app.sh CLASS COMMAND [ARG...]\n' >&2
    exit 2
}

CLASS="$1"; shift

command -v jq >/dev/null || {
    "$NOTIFY" -u critical -t settings -i dialog-error \
        "Settings" "jq is missing - it is how this reads i3"
    exit 1
}

# The one failure worth a popup. A bar button that does nothing because the
# app was never installed looks identical to a bar button that is broken, and
# the fix - run the installer - is not guessable from a dead click.
command -v "$1" >/dev/null || {
    "$NOTIFY" -u critical -t settings -i dialog-error \
        "$1" "not installed - run installer/postinstall.sh"
    exit 1
}

existing="$(i3-msg -t get_tree 2>/dev/null | jq -r --arg c "$CLASS" '
    [recurse(.nodes[]?, .floating_nodes[]?)
     | select(.window != null
              and ((.window_properties.class // "") | ascii_downcase)
                  == ($c | ascii_downcase))]
    | .[0].id // empty')"

if [[ -n "$existing" ]]; then
    # focus on a con_id switches to its workspace and its output, so this
    # lands on the window wherever it was left.
    i3-msg -q "[con_id=$existing] focus" >/dev/null
    exit 0
fi

# setsid, not a bare background job: theme_init.sh restarts the bars on every
# wallpaper change, and polybar's launch.sh stops them by name. A settings
# window started from a bar click is a child of that bar, and killing a
# process group takes the window with it - so the app would vanish mid-use the
# next time the wallpaper rotated. A new session detaches it from all of that.
setsid "$@" >/dev/null 2>&1 &
