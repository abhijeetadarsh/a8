#!/usr/bin/env bash
#
# camera.sh - find the webcam, and open the app that configures it.
#
#   camera.sh settings      open the camera settings app on the first camera
#   camera.sh present       exit 0 if this machine has a camera at all
#   camera.sh devices       one line per camera: /dev/videoN<TAB>name
#   camera.sh list          the same for a terminal, saying what has it open
#
# The bar button is [module/camera] in polybar's user_modules.ini: `present`
# is its exec-if, so the icon is drawn on a laptop and absent on a desktop
# with nothing plugged in, and `settings` is its click.
#
# Nothing here installs or loads anything. A UVC webcam - which is every
# built-in one and almost every USB one - is handled by uvcvideo, which is in
# the kernel and autoloads when the device appears. postinstall.sh's camera
# step exists to say so and to check the two things that do go wrong: the
# userspace tools being absent, and the device nodes not being readable by
# you. There is no driver to install.
#
# --- why /dev/video0 is not "the camera" ------------------------------------
#
# A UVC device registers *two* nodes: one that produces frames and one that
# produces per-frame metadata. So the two webcams on this laptop come out as
# four /dev/video*, and `guvcview` with no arguments - which takes video0 -
# is right only by luck. It is luck that runs out: unplug a USB camera and
# plug it back in and the numbering moves.
#
# What separates the two is a per-node capability, and the trap is that the
# obvious place to read it is the wrong one. `v4l2-ctl --info` prints both
# `Capabilities`, which is the union over every node the physical device owns
# and therefore says "Video Capture" for the metadata node too, and
# `Device Caps`, which is that node alone. Opening a metadata node is not an
# error - it succeeds and then never returns a frame, which looks exactly
# like a camera that is broken or in use.
#
# udev has already worked this out and left the answer on the node as
# ID_V4L_CAPABILITIES=:capture:, so that is what this reads. It needs no
# package beyond systemd, which matters because the bar asks this question
# before the install step that provides v4l-utils has necessarily run.

set -uo pipefail

NOTIFY="$HOME/.config/i3/script/notify.sh"
APP="$HOME/.config/i3/script/app.sh"

# guvcview rather than a plain viewer: the ask is a settings window, and this
# is the one that puts every UVC control the device exposes - exposure, gain,
# white balance, resolution, frame rate - next to a live preview, so a slider
# can be judged by what it does to the picture instead of by its name.
CAMERA_APP="${CAMERA_APP:-guvcview}"
# Matched case-insensitively by app.sh, which matters more than it looks:
# guvcview puts up two windows and capitalises them differently - `guvcview`
# for the preview, `Guvcview` for the controls. Either spelling alone finds
# only one of them, so a second click on the bar button would raise nothing
# half the time and start a third window. The i3 config floats both with the
# same (?i) trick.
CAMERA_APP_CLASS="${CAMERA_APP_CLASS:-guvcview}"

# --- what is a camera -------------------------------------------------------

# /dev/videoN<TAB>name, capture nodes only, in device order.
#
# sort -V, not the shell's glob order: that is lexical, so a machine with ten
# or more nodes would put video10 between video1 and video2 and "the first
# camera" would stop meaning the first one.
capture_devices() {
    local dev props caps name
    for dev in /dev/video*; do
        [[ -c "$dev" ]] || continue

        props="$(udevadm info --query=property --name="$dev" 2>/dev/null)"
        caps="$(sed -n 's/^ID_V4L_CAPABILITIES=//p' <<< "$props")"

        if [[ -n "$caps" ]]; then
            [[ "$caps" == *:capture:* ]] || continue
        else
            # No udev answer - a node that appeared before its rules ran, or a
            # driver udev has no rule for. Fall back to asking the device.
            # Bit 0 of Device Caps is V4L2_CAP_VIDEO_CAPTURE; Capabilities is
            # deliberately not used here, see the header.
            local hex
            hex="$(v4l2-ctl -d "$dev" --info 2>/dev/null |
                sed -n 's/^[[:space:]]*Device Caps[[:space:]]*:[[:space:]]*0x\([0-9a-fA-F]*\).*/\1/p')"
            [[ -n "$hex" ]] || continue
            (( 0x$hex & 0x1 )) || continue
        fi

        name="$(sed -n 's/^ID_V4L_PRODUCT=//p' <<< "$props")"
        [[ -n "$name" ]] || name="$(<"/sys/class/video4linux/${dev##*/}/name" 2>/dev/null)"
        printf '%s\t%s\n' "$dev" "${name:-camera}"
    done | sort -V
}

first_camera() { capture_devices | head -1 | cut -f1; }

# What has the device open. Reading it costs nothing and it is the answer to
# the only question a camera raises in normal use - "why is it busy" - which
# is otherwise a guess between Firefox, a leftover preview and the driver.
holders_of() {
    local pid names=""
    for pid in $(fuser "$1" 2>/dev/null); do
        names+="$(ps -p "$pid" -o comm= 2>/dev/null), "
    done
    printf '%s' "${names%, }"
}

# --- actions ----------------------------------------------------------------

settings() {
    local dev
    dev="$(first_camera)"

    # Said out loud rather than left to the app. guvcview with no camera opens
    # a window and reports the failure inside it, which is a window you then
    # have to close to find out nothing is plugged in.
    [[ -n "$dev" ]] || {
        "$NOTIFY" -u critical -t camera -i camera-off \
            "Camera" "no camera found - nothing on this machine captures video"
        exit 1
    }

    # --device, not guvcview's default: its default is /dev/video0, which is
    # the metadata node of some other device as often as it is this camera.
    "$APP" "$CAMERA_APP_CLASS" "$CAMERA_APP" --device="$dev"
}

list() {
    local dev name held any=0
    while IFS=$'\t' read -r dev name; do
        any=1
        held="$(holders_of "$dev")"
        if [[ -n "$held" ]]; then
            printf '%-14s %s  (in use by %s)\n' "$dev" "$name" "$held"
        else
            printf '%-14s %s\n' "$dev" "$name"
        fi
    done < <(capture_devices)
    (( any )) || printf 'no camera found\n'
}

case "${1:-list}" in
    settings) settings ;;
    present)  [[ -n "$(first_camera)" ]] ;;
    devices)  capture_devices ;;
    list)     list ;;
    --help|-h)
        awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
        ;;
    *)
        printf 'camera: unknown action: %s (try --help)\n' "$1" >&2
        exit 2
        ;;
esac
