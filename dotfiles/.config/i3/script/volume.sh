#!/usr/bin/env bash
#
# volume.sh - move the volume, and show where it landed.
#
#   volume.sh up            raise the default sink by $VOLUME_STEP (10%)
#   volume.sh down          lower it
#   volume.sh mute          toggle the sink
#   volume.sh micmute       toggle the default source
#   volume.sh show          report the current state, change nothing
#
# Bound to the XF86Audio* keys in the i3 config.
#
# The notification carries dunst's progress bar, and every call tags it the
# same, so holding the key down redraws one popup instead of stacking ten - see
# notify.sh for what the tag does.
#
# Why the level is computed here rather than handed to pactl as `+10%`:
#
#   - `pactl set-sink-volume @DEFAULT_SINK@ +10%` has no ceiling. Six presses
#     put a PipeWire sink at 160%, which is software gain applied after the
#     mixer - it clips, and nothing on screen says that is what you are
#     hearing. This clamps at 100.
#   - The bar has to show the value that was actually set. Reading it back
#     after the fact is a second round trip that can disagree with what you
#     just asked for.
#
# Muting is left alone by up/down on purpose: a volume key that silently
# unmutes is how you end up broadcasting a meeting to a room.

set -uo pipefail

NOTIFY="$HOME/.config/i3/script/notify.sh"
STEP="${VOLUME_STEP:-10}"

SINK="@DEFAULT_SINK@"
SOURCE="@DEFAULT_SOURCE@"

ACTION="${1:-show}"

command -v pactl >/dev/null || {
    "$NOTIFY" -u critical -i dialog-error -t volume \
        "Volume" "pactl is missing - is pipewire-pulse installed?"
    exit 1
}

# pactl prints one line per channel:
#
#   Volume: front-left: 49152 /  75% / -7.50 dB,   front-right: ...
#
# Every channel is set to the same value here, so the first percentage is the
# volume. grep -o rather than a field index: the number of channels, and the
# width pactl pads the percentage to, both vary.
sink_volume() {
    pactl get-sink-volume "$SINK" 2>/dev/null |
        grep -oP '\d+(?=%)' | head -1
}

is_muted() {
    [[ "$(pactl "get-$1-mute" "$2" 2>/dev/null)" == *yes* ]]
}

# Which speaker icon: the notification should be readable from the corner of
# your eye, and the glyph is what carries that, not the number.
sink_icon() {
    local vol="$1"
    is_muted sink "$SINK" && { printf 'audio-volume-muted'; return; }
    if   (( vol == 0 )); then printf 'audio-volume-muted'
    elif (( vol < 34 )); then printf 'audio-volume-low'
    elif (( vol < 67 )); then printf 'audio-volume-medium'
    else                      printf 'audio-volume-high'
    fi
}

report_sink() {
    local vol icon body
    vol="$(sink_volume)"
    [[ "$vol" =~ ^[0-9]+$ ]] || {
        "$NOTIFY" -u critical -i dialog-error -t volume \
            "Volume" "no default sink - is anything playing audio?"
        exit 1
    }
    icon="$(sink_icon "$vol")"
    if is_muted sink "$SINK"; then
        body="muted at ${vol}%"
    else
        body="${vol}%"
    fi
    # The bar keeps showing the level while muted, so unmuting is visibly a
    # return to where you were rather than a jump from nothing.
    "$NOTIFY" -u low -t volume -T 1500 -i "$icon" -p "$vol" "Volume" "$body"
}

report_source() {
    if is_muted source "$SOURCE"; then
        "$NOTIFY" -u low -t microphone -T 1500 \
            -i audio-input-microphone-muted "Microphone" "muted"
    else
        "$NOTIFY" -u low -t microphone -T 1500 \
            -i audio-input-microphone "Microphone" "on"
    fi
}

case "$ACTION" in
    up|down)
        cur="$(sink_volume)"
        [[ "$cur" =~ ^[0-9]+$ ]] || cur=0
        if [[ "$ACTION" == up ]]; then
            new=$(( cur + STEP ))
            (( new > 100 )) && new=100
        else
            new=$(( cur - STEP ))
            (( new < 0 )) && new=0
        fi
        pactl set-sink-volume "$SINK" "${new}%" >/dev/null 2>&1
        report_sink
        ;;
    mute)
        pactl set-sink-mute "$SINK" toggle >/dev/null 2>&1
        report_sink
        ;;
    micmute)
        pactl set-source-mute "$SOURCE" toggle >/dev/null 2>&1
        report_source
        ;;
    show)
        report_sink
        ;;
    mic|micshow)
        report_source
        ;;
    --help|-h)
        awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
        ;;
    *)
        printf 'volume: unknown action: %s (try --help)\n' "$ACTION" >&2
        exit 2
        ;;
esac
