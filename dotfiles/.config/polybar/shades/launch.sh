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

for m in "${MONITORS[@]}"; do
    [[ -z "$m" ]] && continue
    MONITOR="$m" polybar -q main -c "$DIR/config.ini" &
done

exit 0
