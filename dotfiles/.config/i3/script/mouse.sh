#!/usr/bin/env bash
#
# mouse.sh - turn the pointer off, and get it back.
#
#   mouse.sh toggle   off if it is on, on if it is off  ($mod+m)
#   mouse.sh off      disable every pointer, take the cursor off the screen
#   mouse.sh on       put them back                     ($mod+Ctrl+m)
#   mouse.sh status   print on / off / none, and exit 0 only when it is on
#   mouse.sh list     every pointer X has, and what this would do to each
#
# Off means off. The touchpad and any mouse stop moving the pointer and stop
# clicking, and the cursor is taken off the screen - so a palm landing on the
# touchpad mid-sentence cannot move focus, follow a link, or drop the window
# into another workspace, and there is no arrow parked in the middle of what
# you are reading.
#
#
# Two halves, because neither implies the other
# ---------------------------------------------
#
# Switching the devices off does not remove the cursor: X goes on drawing the
# arrow wherever it was abandoned. Hiding the cursor does not stop the input:
# an invisible pointer still clicks, and clicking something you cannot see is
# worse than clicking something you can. So this does both, and `on` undoes
# both.
#
#
# Which devices, and the two that must be left alone
# --------------------------------------------------
#
# Slave pointers, which is what a real mouse or touchpad appears as. Not the
# master ("Virtual core pointer") - X has no switch for it, and it is the thing
# the arrow belongs to. And deliberately not "Virtual core XTEST pointer",
# which is how *programs* move the pointer: screenshot.sh asks xdotool where
# the pointer is to work out which monitor to capture, and i3's own
# mouse_warping puts the cursor on an output when focus moves there. Disabling
# XTEST would break both and would not stop one physical device, because it has
# no buttons of its own to stop.
#
# The list comes from what X calls each device, never from its name. A device
# whose name says "Keyboard" can be a slave pointer, and on this laptop one is:
# the USB mouse presents "HID 1bcf:08a0 Keyboard" twice, once as a keyboard for
# its extra keys and once as a pointer. Filtering by name would leave that half
# of the mouse live, which looks exactly like the script not working.
#
#
# Why hiding the cursor needs a process and not a command
# -------------------------------------------------------
#
# The X call that hides a cursor - XFixesHideCursor - is undone as soon as the
# client that asked for it disconnects. There is no "hide the cursor and exit";
# something has to stay connected for as long as the cursor is to stay hidden.
# That something is unclutter, which is why it is a dependency rather than one
# more thing this script does by itself.
#
# Arch's `unclutter` package is unclutter-xfixes, the rewrite: it hides through
# XFixes instead of parking a fake window with a transparent cursor under the
# pointer, so it does not fight the window manager. Two flags matter here:
#
#   --start-hidden   hide now, rather than after the timeout has passed. This
#                    is a key press, not an idle timer.
#   --timeout 0      re-hide the instant the pointer stops moving. It is not
#                    dead weight even with the devices off, because i3 warping
#                    the pointer onto another output *is* movement and unhides
#                    it - without this the cursor would quietly come back the
#                    first time you changed monitor with $mod+period.
#
# If unclutter is not installed the input half still happens and the
# notification says the cursor stayed. Half of this working is worth having;
# refusing to disable the touchpad because an arrow is still visible is not.
#
#
# X is the state; the file is only the list
# -----------------------------------------
#
# Whether the pointer is off is asked of xinput every time, never read back
# from a file. The state directory lives in $XDG_RUNTIME_DIR, which survives a
# restart of X - and X comes back with every device enabled, so a file saying
# "off" can easily outlive the fact. Asking cannot be wrong.
#
# What the file *is* for is which devices to switch back on: the ones this
# script switched off, and no others. A device you disabled by hand - a PS/2
# port inventing button presses, say - is left out of the list when it is
# already off, so `on` leaves it off too.
#
# With one exception, and it is the important one: if the list is missing or
# nothing in it still matches, `on` enables every pointer that is off. A
# pointer that will not come back is a far worse failure than re-enabling
# something somebody had switched off on purpose, and `on` is the command you
# reach for when you have no pointer to reach with.
#
#
# The ways back
# -------------
#
# $mod+m toggles, and $mod+Ctrl+m is `on` unconditionally - the one to hit when
# you are not sure which state you are in, the same way $mod+Shift+b is for
# blanked screens. Both are keyboard-only on purpose.
#
# Plugging a USB mouse in while the pointer is off also works, and is worth
# knowing about: X enables a newly arrived device, so it simply moves the
# cursor. Toggling back on afterwards leaves it alone, since it is not on the
# list of things that were switched off.
#
# The notification is not optional here the way it is in brightness.sh. Every
# other script in this directory reports to a screen you can still click on;
# this one has just taken the pointer away, so the popup naming the key that
# undoes it is the whole safety net. --quiet exists for scripting.

set -uo pipefail

NOTIFY="$HOME/.config/i3/script/notify.sh"

STATE="${XDG_RUNTIME_DIR:-/tmp}/i3-mouse-$USER"
LIST="$STATE/disabled"          # "id<TAB>name" per device we switched off

# argv[0] for the unclutter this script starts, and the only thing that makes
# that process identifiable as ours. See show_cursor.
MARK="i3-mouse-unclutter"

mkdir -p "$STATE" 2>/dev/null

QUIET=0
CMD=""

while (( $# )); do
    case "$1" in
        -q|--quiet) QUIET=1 ;;
        -h|--help)
            awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
            exit 0 ;;
        --) shift; break ;;
        -*) printf 'mouse: unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
        *)  CMD="$1" ;;
    esac
    shift
done

[[ -z "$CMD" && $# -gt 0 ]] && CMD="$1"

# No default command. Every one of them either changes the pointer or prints
# something, and guessing which was meant is not worth the chance of a bare
# `mouse.sh` in a terminal leaving someone without a mouse.
if [[ -z "$CMD" ]]; then
    printf 'mouse: nothing to do - one of toggle, off, on, status, list (try --help)\n' >&2
    exit 2
fi

# A notification, unless --quiet. Never fatal: the pointer has still been
# switched off whether or not anything could say so.
say() {
    local summary="$1" body="${2:-}" icon="${3:-input-mouse}"
    (( QUIET )) && return 0
    "$NOTIFY" -t mouse -i "$icon" -T 6000 "$summary" "$body" >/dev/null 2>&1 || true
}

fail() {
    printf 'mouse: %s\n' "$1" >&2
    say "Mouse" "$1" dialog-error
    exit 1
}

command -v xinput >/dev/null ||
    fail "xinput is not installed - it is how the pointer is switched off (pacman -S xorg-xinput)"

# --- what X has -------------------------------------------------------------

# Candidate devices, as "id<TAB>name<TAB>slave|floating".
#
# Two brackets, not one, and the second is the whole reason this script can
# switch the pointer back on. A disabled device is *detached from its master*:
# it stops being "[slave  pointer]" under the Virtual core pointer and moves to
# the bottom of the list as "[floating slave]", with a different tree glyph and
# no statement anywhere that it is a pointer. Match only the first bracket, and
# every device this script disables becomes invisible to it the instant it
# disables them - `status` answers "no pointer on this machine", and `toggle`
# refuses to turn back on a mouse it can no longer find. That is a locked-out
# keyboard-only session, from a script whose entire job is not to cause one.
raw_devices() {
    xinput list 2>/dev/null | awk '
        {
            if ($0 ~ /\[slave +pointer/)        kind = "slave"
            else if ($0 ~ /\[floating slave\]/) kind = "floating"
            else next
            if (!match($0, /id=[0-9]+/)) next
            id   = substr($0, RSTART + 3, RLENGTH - 3)
            name = substr($0, 1, RSTART - 1)
            sub(/^[^[:alnum:]]+/, "", name)     # the tree glyphs xinput draws
            sub(/[[:space:]]+$/, "", name)
            if (name ~ /XTEST/) next
            printf "%s\t%s\t%s\n", id, name, kind
        }'
}

# Every pointer, on or off, as "id<TAB>name".
#
# Floating means "attached to no master", which is what a disabled pointer
# looks like - but it is also what a *floated keyboard* looks like, and the
# list says only "[floating slave]" for both. Buttons settle it: xinput's
# per-device detail reports XIButtonClass for anything with buttons, which is
# every pointer and no keyboard. Only floating devices pay for that extra call.
pointers() {
    local id name kind
    while IFS=$'\t' read -r id name kind; do
        [[ -n "$id" ]] || continue
        if [[ "$kind" == floating ]]; then
            xinput list "$id" 2>/dev/null | grep -q XIButtonClass || continue
        fi
        printf '%s\t%s\n' "$id" "$name"
    done < <(raw_devices)
}

is_enabled() {
    [[ "$(xinput list-props "$1" 2>/dev/null |
          awk -F: '/Device Enabled/ { gsub(/[^0-9]/, "", $2); print $2; exit }')" == 1 ]]
}

# on / off / none, worked out from the devices themselves.
state() {
    local id name any=0
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] || continue
        any=1
        is_enabled "$id" && { printf 'on\n'; return 0; }
    done < <(pointers)
    if (( any )); then printf 'off\n'; else printf 'none\n'; fi
}

# --- the cursor -------------------------------------------------------------

# The unclutters this script started, one pid per line. Empty means none.
#
# Found by argv[0], not by a pid written to a file, and not by name.
#
# Not by name, because `unclutter` is a program somebody may well be running
# for its actual purpose - hiding the cursor while they type - and a sweep by
# name would kill that too. Nothing here may touch a process it did not start.
#
# Not by a pid file either, though that was the obvious design. The cursor
# hiding outlives this script by definition, so the only record of it would be
# that file - and if the file goes and the process stays, the cursor is hidden
# with nothing left that is allowed to unhide it. A pointer that works under an
# arrow that is not there, permanently, with `mouse.sh on` powerless to fix it.
# The tag cannot be lost that way: it is carried by the process itself.
#
# Three things must all hold: the process is ours (-O), it really is unclutter
# (comm is set from the binary at exec and argv[0] cannot forge it), and its
# argv[0] is the marker only this script passes.
our_unclutters() {
    local d pid found=1
    for d in /proc/[0-9]*; do
        pid="${d#/proc/}"
        [[ -O "$d" ]] || continue
        [[ "$(cat "$d/comm" 2>/dev/null)" == unclutter ]] || continue
        [[ "$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -1)" == "$MARK" ]] || continue
        printf '%s\n' "$pid"
        found=0
    done
    return "$found"
}

hide_cursor() {
    command -v unclutter >/dev/null || return 1
    our_unclutters >/dev/null && return 0       # already hidden by ours
    # 9>&- is not tidiness. unclutter outlives this script by design, and a
    # child inherits every open descriptor - including fd 9, which is the lock
    # below. Leave it open and unclutter holds the lock for as long as the
    # cursor is hidden, so the next run blocks on flock forever: $mod+m does
    # nothing, $mod+Ctrl+m does nothing, and the pointer stays off with no way
    # back short of a terminal. The one process that must not hold this lock is
    # the one that only exists while the pointer is off.
    bash -c 'exec -a "$1" unclutter --timeout 0 --start-hidden' _ "$MARK" \
        </dev/null >/dev/null 2>&1 9>&- &
    return 0
}

# Let the cursor back. Killing the client is what does it: the hide is the
# server's, held only for as long as the client that asked stays connected, so
# the arrow is back the moment this returns.
show_cursor() {
    local pid
    while read -r pid; do
        [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
    done < <(our_unclutters)
}

# --- off and on -------------------------------------------------------------

turn_off() {
    local id name n=0 first=""

    : > "$LIST"
    while IFS=$'\t' read -r id name; do
        [[ -n "$id" ]] || continue
        # Already off, by hand or by something else: leave it, and keep it out
        # of the list so `on` leaves it too.
        is_enabled "$id" || continue
        if xinput disable "$id" 2>/dev/null; then
            printf '%s\t%s\n' "$id" "$name" >> "$LIST"
            n=$((n + 1))
            [[ -z "$first" ]] && first="$name"
        else
            printf 'mouse: could not disable %s (id %s)\n' "$name" "$id" >&2
        fi
    done < <(pointers)

    if (( n == 0 )); then
        rm -f "$LIST"
        say "Mouse already off" "nothing left to disable - Super+Ctrl+M brings it back"
        return 0
    fi

    # After the input, not before: with the devices still live, a twitch of the
    # touchpad between the two would unhide the cursor again.
    local body
    if hide_cursor; then
        body="$n device(s) off, cursor hidden"
    else
        body="$n device(s) off - install unclutter to hide the cursor too"
    fi

    say "Mouse off" "$body
Super+M or Super+Ctrl+M brings it back"
    return 0
}

turn_on() {
    local id name n=0

    show_cursor

    if [[ -s "$LIST" ]]; then
        while IFS=$'\t' read -r id name; do
            [[ -n "$id" ]] || continue
            # An id only means something while it is still the same device: X
            # hands them out again as things are plugged and unplugged, so the
            # name is checked before anything is switched on.
            [[ "$(xinput list --name-only "$id" 2>/dev/null)" == "$name" ]] || continue
            xinput enable "$id" 2>/dev/null && n=$((n + 1))
        done < "$LIST"
    fi

    # Nothing on the list, or none of it still matches: switch on every pointer
    # that is off. See the header - this is the command you reach for when you
    # have no pointer to reach with, and it has to work without the file.
    if (( n == 0 )); then
        while IFS=$'\t' read -r id name; do
            [[ -n "$id" ]] || continue
            if ! is_enabled "$id"; then
                xinput enable "$id" 2>/dev/null && n=$((n + 1))
            fi
        done < <(pointers)
    fi

    rm -f "$LIST"

    if (( n == 0 )); then
        say "Mouse already on" "nothing was disabled"
    else
        say "Mouse on" "$n device(s) back"
    fi
    return 0
}

# --- commands ---------------------------------------------------------------

# One at a time. Two presses in the same instant - a key repeat, a double tap -
# would otherwise both read "on", both disable, and the second would overwrite
# the list the first one wrote with an empty one, leaving nothing to enable.
lock() {
    exec 9>"$STATE/lock" 2>/dev/null || return 0
    # -w, never a bare flock. Serialising two key presses is worth a couple of
    # seconds; it is not worth any chance at all of the key that gives the
    # pointer back hanging on a lock somebody else is holding. If the wait runs
    # out, go ahead anyway - a racing second copy is a recoverable mess, a key
    # that does nothing is not.
    flock -w 2 9 2>/dev/null || true
}

case "$CMD" in
    toggle)
        lock
        case "$(state)" in
            on)   turn_off ;;
            off)  turn_on ;;
            none) fail "X reports no pointer device at all - nothing to toggle" ;;
        esac
        ;;
    off|disable)
        lock
        [[ "$(state)" == none ]] && fail "X reports no pointer device at all"
        turn_off
        ;;
    on|enable)
        lock
        turn_on
        ;;
    status)
        s="$(state)"
        printf '%s\n' "$s"
        [[ "$s" == on ]]
        ;;
    list)
        printf '%-4s %-8s %s\n' ID STATE NAME
        while IFS=$'\t' read -r id name; do
            [[ -n "$id" ]] || continue
            if is_enabled "$id"; then printf '%-4s %-8s %s\n' "$id" enabled "$name"
            else                      printf '%-4s %-8s %s\n' "$id" disabled "$name"
            fi
        done < <(pointers) | sort -n
        ;;
    *)
        printf 'mouse: unknown command: %s - one of toggle, off, on, status, list\n' "$CMD" >&2
        exit 2 ;;
esac
