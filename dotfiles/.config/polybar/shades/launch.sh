#!/usr/bin/env bash
#
# launch.sh - start one bar per connected monitor.
#
# polybar has no concept of "all monitors": one process draws one bar on one
# output. The previous version started a single unnamed instance, which is why
# a second screen got no bar at all. This starts one per output and passes the
# output name through $MONITOR, which config.ini reads.
#
# theme_init.sh calls this after regenerating the palette, and $mod+Shift+m
# calls it after re-detecting monitors.

DIR="$HOME/.config/polybar/shades"

# Terminate already running bar instances.
killall -q polybar

# Wait until the processes have been shut down.
while pgrep -u "$UID" -x polybar >/dev/null; do sleep 1; done

mapfile -t MONITORS < <(polybar --list-monitors 2>/dev/null | cut -d: -f1)

# --list-monitors can come up empty very early in startup, before RandR has
# settled. Fall back to xrandr, then to a single unnamed bar, so a slow
# monitor never leaves you with no bar at all.
if (( ${#MONITORS[@]} == 0 )) && command -v xrandr >/dev/null; then
    mapfile -t MONITORS < <(xrandr --query | awk '/ connected/ {print $1}')
fi

if (( ${#MONITORS[@]} == 0 )); then
    polybar -q main -c "$DIR/config.ini" &
    exit 0
fi

# The tray goes on exactly one bar. _NET_SYSTEM_TRAY_S0 is a single X selection,
# so if every instance asked for it they would race and the losers would log an
# error. bar/main-tray is bar/main with the tray module added, and only the
# primary output gets it - the primary as xrandr reports it, or the first bar
# started when nothing is marked primary.
#
# This is what makes nm-applet and blueman-applet visible at all: they dock an
# icon into the tray and have no other interface.
TRAY_ON="$(xrandr --query 2>/dev/null | awk '/ connected primary/ { print $1; exit }')"
[[ -z "$TRAY_ON" ]] && TRAY_ON="${MONITORS[0]}"

for m in "${MONITORS[@]}"; do
    [[ -z "$m" ]] && continue
    bar=main
    [[ "$m" == "$TRAY_ON" ]] && bar=main-tray
    MONITOR="$m" polybar -q "$bar" -c "$DIR/config.ini" &
done

exit 0
