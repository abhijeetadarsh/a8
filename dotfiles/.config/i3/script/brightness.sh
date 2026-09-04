#!/usr/bin/env bash
#
# brightness.sh - per-monitor brightness, driven by the bar's scroll wheel.
#
#   brightness.sh up      OUTPUT [STEP]  raise OUTPUT by STEP percent (5)
#   brightness.sh down    OUTPUT [STEP]  lower it
#   brightness.sh set     OUTPUT PERCENT jump to an absolute level
#   brightness.sh get     OUTPUT         print the level as a bare number
#   brightness.sh off     OUTPUT         blank the backlight, remembering the level
#   brightness.sh on      OUTPUT         bring it back to where it was
#   brightness.sh toggle  OUTPUT         whichever of those two applies
#   brightness.sh wake                   un-blank every screen, no target needed
#   brightness.sh watch   OUTPUT         the bar's readout; never exits
#   brightness.sh status  OUTPUT         that readout once, and exit
#   brightness.sh supported OUTPUT       exit 0 if OUTPUT can be dimmed at all
#   brightness.sh list                   every output, its backend, its level
#   brightness.sh refresh                forget the cached output->backend map
#
# OUTPUT is an xrandr name - eDP-1, HDMI-1. polybar hands it in as $MONITOR:
# launch.sh starts one process per screen with MONITOR set in its environment,
# so [module/brightness] in each bar acts on the screen that bar is drawn on
# and no other. That is the entire point of this script. A scroll over the
# laptop panel must not move the external monitor, and there is no such thing
# as "the" brightness on a two-screen desktop.
#
# Add `--notify` to up/down/set for a dunst popup with a progress bar. The bar
# is silent by default: the module you just scrolled is already showing you the
# number, and a popup on top of it is noise. A keybinding has no such readout,
# so that is what the flag is for.
#
#
# Two unrelated mechanisms hide behind the one interface
# -----------------------------------------------------
#
# sysfs - the internal panel. The kernel exposes a real backlight device at
#   /sys/class/backlight/<card>, brightnessctl writes it (through logind, so no
#   root and no setuid), and the write lands in about three milliseconds. Only
#   panels wired to the GPU's backlight controller get one of these; on this
#   machine that is eDP-1 and nothing else.
#
# ddc - external monitors. There is no kernel backlight device for them; the
#   panel's own controller is reached over the i2c bus behind the video cable,
#   with the DDC/CI protocol, VCP feature 0x10. ddcutil speaks it. Two costs
#   come with that and both shape the code below:
#
#     - a write takes ~240ms and a read ~400ms, against ~3ms for sysfs
#     - the monitor may simply not answer. DDC/CI is optional, some panels ship
#       with it off in the OSD, and laptop panels never have it
#
#   The latency is why nothing here calls ddcutil on the scrolling path. One
#   flick of the wheel is a dozen events in under a second; sending a dozen
#   240ms writes would still be draining a queue seconds after you stopped, and
#   the monitor would visibly stair-step through every intermediate value. So a
#   scroll only moves a number in a file, and a single background applier
#   writes the value those events added up to - see ddc_apply.
#
# The map from output to mechanism is worked out once and cached, because
# `ddcutil detect` takes the best part of a second and the scroll path cannot
# afford it. Plugging a monitor in invalidates it; `refresh`, or restarting the
# bar, rebuilds it.
#
#
# Why the bar is pushed to, not polled
# ------------------------------------
#
# The readout has to change in the same frame as the wheel or it feels broken,
# and for the DDC outputs the true value cannot be read back at that speed. So
# [module/brightness] is a `tail = true` script that blocks on a fifo, and
# every change writes one byte into it. No polling, no interval, no i2c traffic
# at rest - and the number on screen is the value we asked for rather than one
# we would have had to spend 400ms re-reading.

set -uo pipefail

NOTIFY="$HOME/.config/i3/script/notify.sh"

STEP_DEFAULT="${BRIGHTNESS_STEP:-5}"

# The laptop panel does not go below this. At 1% the screen is black in any lit
# room, including the bar you would need to see to scroll back up, and the
# hardware keys are not bound to anything - so the floor is the difference
# between "dim" and "reboot to get your screen back". External monitors keep a
# floor of 0: they have their own OSD and a power button, so a black one is
# always recoverable.
MIN_SYSFS="${BRIGHTNESS_MIN:-5}"
MIN_DDC=0

# How long the applier waits before committing a burst of scroll events. Long
# enough to swallow a flick of the wheel, short enough that a single deliberate
# click still feels immediate.
DDC_SETTLE="${BRIGHTNESS_SETTLE:-0.12}"

# DDC/CI is not a reliable bus. A monitor that is switching input, waking, or
# just busy will NAK, and retrying forever would pin a core and spam the i2c
# bus for as long as the monitor stayed unhappy.
DDC_TRIES=3

STATE_DIR="${XDG_RUNTIME_DIR:-/tmp/$UID}/brightness"
MAP="$STATE_DIR/map"

mkdir -p "$STATE_DIR" 2>/dev/null

state() { printf '%s/%s.%s' "$STATE_DIR" "${1//\//_}" "$2"; }

# Write without ever letting a reader see a half-written file: a scroll handler
# and the applier read these while each other writes. The temp name carries the
# pid because two scroll events can be in flight at once - a shared .tmp would
# have them truncating one file under each other and racing to rename it, which
# is exactly the corruption the rename was there to prevent.
put() { printf '%s\n' "$2" > "$1.$$.tmp" && mv -f "$1.$$.tmp" "$1"; }
getf() { cat "$1" 2>/dev/null; }

die() { printf 'brightness: %s\n' "$1" >&2; exit 1; }


## the output -> backend map ##################################################

# A signature of what is plugged in, cheap enough to sit on the scrolling path:
# a handful of small sysfs reads and not one process spawned.
#
# It changes exactly when a connector's status does, which is the event that
# makes a cached map wrong. i2c bus numbers are not stable across a replug - the
# bus that was HDMI-1 can come back as a different number, or belong to a
# different monitor - so a map kept from before one would quietly send
# brightness to the wrong screen. That is the failure this exists to prevent.
drm_signature() {
    local f st sig=""
    for f in /sys/class/drm/card*-*/status; do
        [[ -r "$f" ]] || continue
        read -r st < "$f" 2>/dev/null || continue
        sig+="${f#/sys/class/drm/}=$st "
    done
    printf '%s' "$sig"
}

# xrandr and DRM do not agree on what a connector is called. The kernel calls
# the external one card1-HDMI-A-1; xrandr, through the modesetting driver,
# calls it HDMI-1 - the connector-type letter is dropped. Rather than encode
# that rule and hope it holds for DP-2 or DVI-I-1, generate both spellings and
# keep whichever one xrandr admits to having. Anything that survives that check
# is a name the caller can actually pass in.
drm_to_xrandr() {
    local drm="$1" base connected="$2" cand
    base="${drm#card*-}"
    for cand in "$base" "$(sed -E 's/^([A-Za-z]+)-[A-Z]-([0-9]+)$/\1-\2/' <<<"$base")"; do
        if grep -qxF "$cand" <<<"$connected"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

# One line per controllable output: NAME <tab> BACKEND <tab> ARGUMENT.
# Costs about a second, almost all of it in `ddcutil detect`, which is why it
# is built at bar startup and read from a file everywhere else.
map_build() {
    local connected dev conn name bus drm

    connected="$(xrandr --query 2>/dev/null | awk '/ connected/ {print $1}')"
    [[ -z "$connected" ]] && return 1

    : > "$MAP.tmp"

    # Backlight devices carry their connector in their sysfs path:
    #   /sys/devices/.../card1/card1-eDP-1/intel_backlight
    # so the panel each one drives is its parent directory, no guessing.
    for dev in /sys/class/backlight/*; do
        [[ -e "$dev/brightness" ]] || continue
        conn="$(basename "$(dirname "$(readlink -f "$dev")")")"
        [[ "$conn" == card*-* ]] || continue
        if name="$(drm_to_xrandr "$conn" "$connected")"; then
            printf '%s\t%s\t%s\n' "$name" sysfs "$(basename "$dev")" >> "$MAP.tmp"
        fi
    done

    # `ddcutil detect --terse` prints a block per display. Blocks headed
    # "Invalid display" are ones it found but cannot drive - the laptop panel
    # appears there, since eDP has an i2c bus for the EDID but no DDC/CI - and
    # taking them would hand us a bus that NAKs every write.
    if command -v ddcutil >/dev/null; then
        local valid=0
        while IFS= read -r line; do
            case "$line" in
                Invalid\ display*) valid=0 bus="" drm="" ;;
                Display\ *)        valid=1 bus="" drm="" ;;
                *I2C\ bus:*)       bus="${line##*/dev/i2c-}" ;;
                *DRM\ connector:*) drm="${line##* }" ;;
            esac
            if (( valid )) && [[ -n "${bus:-}" && -n "${drm:-}" ]]; then
                if name="$(drm_to_xrandr "$drm" "$connected")"; then
                    # A panel with a real backlight device is driven through it:
                    # sysfs is 80x faster and always answers.
                    grep -qP "^\Q$name\E\t" "$MAP.tmp" ||
                        printf '%s\t%s\t%s\n' "$name" ddc "$bus" >> "$MAP.tmp"
                fi
                bus="" drm=""
            fi
        done < <(ddcutil detect --terse 2>/dev/null)
    fi

    mv -f "$MAP.tmp" "$MAP"
    put "$MAP.sig" "$(drm_signature)"
}

# BACKEND and ARG for an output, rebuilding the map once if it is not in there
# - which is what happens on the first call after a monitor is plugged in.
BACKEND="" ARG=""
map_lookup() {
    local out="$1" line tried=0

    if [[ "$(drm_signature)" != "$(getf "$MAP.sig")" ]]; then
        # What is plugged in has changed, so both halves of the cache are
        # suspect: the bus a name maps to, and the level remembered against that
        # name - which belonged to whatever monitor used to be there. Drop the
        # levels too, so each output re-seeds from its own hardware rather than
        # inheriting a stranger's. Only the DDC outputs keep a cached level; the
        # internal panel is always read straight from sysfs.
        map_build || return 1
        rm -f "$STATE_DIR"/*.desired "$STATE_DIR"/*.applied
        tried=1
    fi

    while :; do
        if [[ -s "$MAP" ]]; then
            line="$(grep -P "^\Q$out\E\t" "$MAP" 2>/dev/null | head -1)"
            if [[ -n "$line" ]]; then
                BACKEND="$(cut -f2 <<<"$line")"
                ARG="$(cut -f3 <<<"$line")"
                return 0
            fi
        fi
        (( tried )) && return 1
        tried=1
        map_build || return 1
    done
}


## reading and writing a level ################################################

clamp() {
    local v="$1" lo="$2"
    (( v < lo )) && v="$lo"
    (( v > 100 )) && v=100
    printf '%s\n' "$v"
}

sysfs_get() {
    local raw max
    raw="$(getf "/sys/class/backlight/$ARG/brightness")"
    max="$(getf "/sys/class/backlight/$ARG/max_brightness")"
    [[ "$raw" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ && "$max" -gt 0 ]] || return 1
    # Rounded, so that reading back what we just set returns the same number
    # and a run of single steps cannot drift.
    printf '%s\n' $(( (raw * 100 + max / 2) / max ))
}

sysfs_set() {
    brightnessctl -d "$ARG" -m set "$1%" >/dev/null 2>&1
}

ddc_read_hw() {
    local out
    out="$(ddcutil --bus "$ARG" getvcp 10 --terse 2>/dev/null)" || return 1
    # `VCP 10 C 25 100` - current value is the fourth field.
    awk '{ if ($3 == "C" || $3 == "SNC" || $3 == "CNC") print $4 }' <<<"$out" | head -1
}

# What to show for a DDC output. The file is authoritative once it exists: it
# is what we last asked the monitor for, it is accurate because every change
# goes through here, and consulting it costs no i2c round trip. Only the first
# call of a session pays the 400ms to find out where the monitor started.
ddc_get() {
    local f v
    f="$(state "$1" desired)"
    v="$(getf "$f")"
    if [[ ! "$v" =~ ^[0-9]+$ ]]; then
        # Under the applier's lock: this is the one other place that talks to
        # the bus, and two DDC transactions interleaved on one i2c line do not
        # politely queue - they corrupt each other, and the monitor lands on a
        # value neither side asked for.
        v="$(
            exec 8>"$(state "$1" lock)"
            flock -w 2 8 || exit 1
            ddc_read_hw
        )"
        [[ "$v" =~ ^[0-9]+$ ]] || return 1
        put "$f" "$v"
        put "$(state "$1" applied)" "$v"
    fi
    printf '%s\n' "$v"
}

# The one process allowed to touch this monitor's i2c bus.
#
# The lock is held for the whole life of the applier, ddcutil calls included,
# so two of them can never drive one bus at once. Any scroll that lands while
# one is running is picked up by its loop, because the loop re-reads `desired`
# every pass; any scroll that lands in the instant one is exiting spawns
# another, which waits for the dying process to release the lock and then sees
# the discrepancy for itself. Between them the two paths cover every ordering,
# so no scroll is silently dropped.
ddc_apply() {
    local out="$1" want last fails=0
    exec 9>"$(state "$out" lock)"
    flock -w 2 9 || exit 0

    while :; do
        want="$(getf "$(state "$out" desired)")"
        last="$(getf "$(state "$out" applied)")"
        [[ "$want" =~ ^[0-9]+$ ]] || break
        [[ "$want" == "$last" ]] && break

        # Coalesce. Everything the wheel does in this window collapses into the
        # single write below, which is what keeps a fast scroll from
        # stair-stepping the panel through a dozen intermediate levels.
        sleep "$DDC_SETTLE"
        want="$(getf "$(state "$out" desired)")"
        [[ "$want" =~ ^[0-9]+$ ]] || break

        if ddcutil --bus "$ARG" setvcp 10 "$want" >/dev/null 2>&1; then
            put "$(state "$out" applied)" "$want"
            fails=0
        else
            fails=$(( fails + 1 ))
            # `applied` is deliberately left stale on failure, so the next
            # scroll retries rather than assuming the monitor took the value.
            (( fails >= DDC_TRIES )) && break
        fi
    done
}

level_get() {
    case "$BACKEND" in
        sysfs) sysfs_get ;;
        ddc)   ddc_get "$1" ;;
        *)     return 1 ;;
    esac
}

level_min() { [[ "$BACKEND" == sysfs ]] && printf '%s\n' "$MIN_SYSFS" || printf '%s\n' "$MIN_DDC"; }

level_set() {
    local out="$1" want="$2"
    case "$BACKEND" in
        sysfs)
            sysfs_set "$want" || return 1
            ;;
        ddc)
            # Return immediately. The number is the bar's truth from here on;
            # the monitor catches up in the background.
            put "$(state "$out" desired)" "$want"
            ( ddc_apply "$out" & ) >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}


## power saving ###############################################################

# Blank the backlight, and remember where to come back to.
#
# Brightness 0 deliberately, and not DDC's power mode. VCP 0xD6 puts an external
# monitor into real DPMS standby and would save more - the panel electronics go
# down too, not just the backlight - but a monitor that is asleep has stopped
# answering DDC, so the command to wake it cannot be delivered. Measured on the
# MSI MAG 255F attached to this machine: `setvcp D6 4` succeeded, every DDC call
# on that bus then failed, and `setvcp D6 1` could not get through. The screen
# came back only when the video signal was re-asserted. A control with no
# reliable way back is not a control, so this does not use it.
#
# Brightness 0 has no such trap. The panel stays awake and keeps answering, so
# the way back is the same call that got here. On an LED-backlit screen the
# backlight is the great majority of what the panel draws, so this is most of
# the saving regardless.
#
# The floor that up/down respect is bypassed here on purpose. That floor exists
# so a stray scroll cannot put a screen into darkness you then cannot see to
# undo. This is not a stray scroll - it is the entire request - and it saves the
# level first, so the way back is one more click on the same spot.
blank() {
    local out="$1" cur
    cur="$(level_get "$out")"
    [[ "$cur" =~ ^[0-9]+$ ]] || return 1
    put "$(state "$out" saved)" "$cur"
    level_set "$out" 0 || return 1
    : > "$(state "$out" blanked)"
}

unblank() {
    local out="$1" saved
    saved="$(getf "$(state "$out" saved)")"
    # 50 rather than nothing if the saved level is missing: coming back to a
    # readable screen matters more than coming back to the exact one.
    [[ "$saved" =~ ^[0-9]+$ ]] || saved=50
    rm -f "$(state "$out" blanked)"
    level_set "$out" "$saved"
}

## the bar ####################################################################

# The ramp, dimmest first: Material Design's brightness set, a sun that grows
# rays as the level climbs. Same shape as the volume module's f026/f027/f028,
# including the part where the dimmest glyph doubles as the off one - f026 is
# both ramp-volume-0 and the muted icon.
#
# These are Nerd Fonts *v3* codepoints (U+F00DB-U+F00E1). The v2 Material range
# is the one that moved and stopped rendering elsewhere in this config, which is
# why every glyph here was checked against the bar's actual font - CaskaydiaCove
# Nerd Font Propo - rather than assumed. If a font update moves them again,
# BRIGHTNESS_GLYPHS replaces the whole ramp without editing this file, and any
# number of levels works: the ramp is indexed by proportion, not by a fixed 7.
IFS=' ' read -r -a GLYPHS <<< "${BRIGHTNESS_GLYPHS:-󰃛 󰃜 󰃝 󰃞 󰃟 󰃠 󰃡}"

glyph_for() {
    local pct="$1" n="${#GLYPHS[@]}"
    (( n == 0 )) && return 0
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    printf '%s' "${GLYPHS[$(( pct * (n - 1) / 100 ))]}"
}

render() {
    local out="$1" v
    v="$(level_get "$out")"
    [[ "$v" =~ ^[0-9]+$ ]] || { printf '\n'; return; }
    # Blanked reads as a state, not as "0%" - the same reason the volume module
    # says "Muted" rather than 0. The number would be true and useless: what you
    # need to know is that the screen is off on purpose and a click brings it
    # back.
    if [[ -e "$(state "$out" blanked)" ]]; then
        # Padded out on purpose. The screen this is drawn on is black, so the
        # only way back with a pointer is a click you cannot aim, and a wider
        # module is a wider thing to hit blindly along the top edge. It costs
        # nothing: the one bar where this is ever rendered is one nobody can
        # see. The reliable way back is still a key - see the bindings in the
        # i3 config.
        printf '%s     off     \n' "${GLYPHS[0]}"
    else
        printf '%s %s%%\n' "$(glyph_for "$v")" "$v"
    fi
}

fifo_of() { state "$1" fifo; }

# Opened read-write, never write-only. A write-only open on a fifo blocks until
# a reader arrives, which would hang the scroll handler solid for as long as
# the bar was not running; read-write never blocks and needs no reader.
poke() {
    local f
    f="$(fifo_of "$1")"
    [[ -p "$f" ]] || return 0
    { exec 4<>"$f"; printf '.' >&4; exec 4>&-; } 2>/dev/null
}

watch_output() {
    local out="$1" f
    f="$(fifo_of "$out")"
    [[ -p "$f" ]] || { rm -f "$f"; mkfifo -m 600 "$f" || die "cannot create $f"; }

    # Seed the cache with one real read now, while a slow call is free - this
    # runs once at bar startup - so the first thing drawn is the monitor's
    # actual level and not a guess.
    render "$out"

    exec 3<>"$f"
    # Drain anything a previous bar's lifetime left in the pipe, so a restart
    # does not redraw once per stale byte.
    while IFS= read -r -t 0.01 -n 256 _ <&3; do :; done 2>/dev/null

    while IFS= read -r -n 1 _ <&3; do
        render "$out"
    done
}


## entry point ################################################################

ACTION="${1:-list}"

# --notify anywhere in the arguments, removed before positional parsing.
WANT_NOTIFY=0
ARGV=()
for a in "$@"; do
    case "$a" in
        --notify|-n) WANT_NOTIFY=1 ;;
        *) ARGV+=("$a") ;;
    esac
done
set -- "${ARGV[@]}"
ACTION="${1:-list}"

# Which screen a call is about, in order of preference: an explicit argument,
# then $MONITOR, then the primary.
#
# $MONITOR is how the bar says it, and it arrives by inheritance rather than as
# an argument. polybar 3.7 does not expand ${env:...} inside a module's exec or
# scroll values - it does expand it in bar keys, which is why `monitor =` in
# config.ini works and put this module on the wrong screen anyway. Passing the
# output in that way silently produced an empty argument and both bars drove
# the primary panel. Inheritance has no such gap: this process is a child of
# the polybar that launch.sh started with MONITOR set, so the value is simply
# already in the environment.
#
# From a keybinding there is no $MONITOR at all - i3 execs with its own
# environment, not a bar's - so the next question is which screen you are
# actually working on, and i3 is the only thing that knows. That is what makes
# a brightness key act on the monitor you are looking at instead of always the
# primary one.
#
# The primary fallback is last: for launch.sh's single-bar path, and for any
# call made when i3 is not answering.
resolve_output() {
    local out="${1:-}"
    [[ -z "$out" ]] && out="${MONITOR:-}"

    if [[ -z "$out" ]] && command -v i3-msg >/dev/null && command -v jq >/dev/null; then
        out="$(i3-msg -t get_workspaces 2>/dev/null |
            jq -r 'map(select(.focused)) | .[0].output // empty' 2>/dev/null)"
    fi

    if [[ -z "$out" ]]; then
        out="$(xrandr --query 2>/dev/null | awk '/ connected primary/ {print $1; exit}')"
        [[ -z "$out" ]] && out="$(xrandr --query 2>/dev/null | awk '/ connected/ {print $1; exit}')"
    fi
    printf '%s\n' "$out"
}

case "$ACTION" in
    up|down|set)
        OUT="$(resolve_output "${2:-}")"
        [[ -n "$OUT" ]] || die "no output given and none could be guessed"
        map_lookup "$OUT" || die "$OUT has no controllable brightness (try: $0 list)"

        cur="$(level_get "$OUT")"
        [[ "$cur" =~ ^[0-9]+$ ]] || die "cannot read the current level of $OUT"

        case "$ACTION" in
            up)   new=$(( cur + ${3:-$STEP_DEFAULT} )) ;;
            down) new=$(( cur - ${3:-$STEP_DEFAULT} )) ;;
            set)  new="${3:-}"; [[ "$new" =~ ^[0-9]+$ ]] || die "set needs a percentage" ;;
        esac
        new="$(clamp "$new" "$(level_min)")"

        # Touching the level at all means the screen is wanted, so it stops
        # being blanked - otherwise the bar would go on reporting "off" for a
        # screen you had just scrolled back up.
        rm -f "$(state "$OUT" blanked)"

        if [[ "$new" != "$cur" ]]; then
            level_set "$OUT" "$new" || die "could not set the brightness of $OUT"
        fi
        poke "$OUT"

        if (( WANT_NOTIFY )) && [[ -x "$NOTIFY" ]]; then
            # One tag for the output, so holding a key redraws one popup on the
            # screen it applies to instead of stacking ten - same reason
            # volume.sh tags its own.
            "$NOTIFY" -i display-brightness -t "brightness-$OUT" -p "$new" -T 1500 \
                "$OUT" "Brightness ${new}%"
        fi
        ;;

    off|on|toggle|blank)
        OUT="$(resolve_output "${2:-}")"
        [[ -n "$OUT" ]] || die "no output given and none could be guessed"
        map_lookup "$OUT" || die "$OUT has no controllable brightness (try: $0 list)"

        case "$ACTION" in
            off|blank) blank "$OUT"   || die "could not blank $OUT" ;;
            on)        unblank "$OUT" || die "could not restore $OUT" ;;
            toggle)
                if [[ -e "$(state "$OUT" blanked)" ]]; then
                    unblank "$OUT" || die "could not restore $OUT"
                else
                    blank "$OUT" || die "could not blank $OUT"
                fi
                ;;
        esac
        poke "$OUT"
        ;;

    wake)
        # Restore every blanked screen at once, with no argument, no focus and
        # no aiming. This is the one to bind to a key: when a panel is dark the
        # things you would normally use to pick a target - seeing which monitor
        # it is, finding the module, hitting it - are exactly what you have
        # lost. Doing nothing quietly when nothing is blanked is the point; it
        # makes the key safe to hit whenever you are unsure.
        [[ -s "$MAP" ]] || map_build || die "could not work out what the outputs are"
        woke=0
        while IFS=$'\t' read -r name backend arg; do
            [[ -n "$name" ]] || continue
            [[ -e "$(state "$name" blanked)" ]] || continue
            BACKEND="$backend" ARG="$arg"
            if unblank "$name"; then
                poke "$name"
                woke=$(( woke + 1 ))
            fi
        done < "$MAP"

        if (( WANT_NOTIFY )) && [[ -x "$NOTIFY" ]]; then
            if (( woke )); then
                "$NOTIFY" -i display-brightness -t brightness-wake -T 1500 \
                    "Displays" "$woke screen(s) back on"
            fi
        fi
        ;;

    get)
        OUT="$(resolve_output "${2:-}")"
        map_lookup "$OUT" || exit 1
        level_get "$OUT"
        ;;

    status)
        OUT="$(resolve_output "${2:-}")"
        map_lookup "$OUT" || { printf '\n'; exit 0; }
        render "$OUT"
        ;;

    watch)
        OUT="$(resolve_output "${2:-}")"
        map_lookup "$OUT" || { printf '\n'; exit 0; }
        watch_output "$OUT"
        ;;

    supported)
        OUT="$(resolve_output "${2:-}")"
        map_lookup "$OUT"
        ;;

    list)
        map_build >/dev/null 2>&1
        [[ -s "$MAP" ]] || { printf 'brightness: no controllable output found\n' >&2; exit 1; }
        while IFS=$'\t' read -r name backend arg; do
            BACKEND="$backend" ARG="$arg"
            printf '%-10s %-6s %-16s %s%%\n' "$name" "$backend" \
                "$( [[ $backend == ddc ]] && echo "/dev/i2c-$arg" || echo "$arg" )" \
                "$(level_get "$name")"
        done < "$MAP"
        ;;

    refresh)
        rm -f "$MAP" "$MAP.sig"
        map_build || die "could not rebuild the output map"
        cut -f1 "$MAP" | while read -r name; do poke "$name"; done
        ;;

    --help|-h)
        awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
        ;;

    *)
        printf 'brightness: unknown action: %s (try --help)\n' "$ACTION" >&2
        exit 2
        ;;
esac
