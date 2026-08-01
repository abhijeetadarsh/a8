#!/usr/bin/env bash
#
# notify.sh - the one way this desktop says that something happened.
#
# Most i3 keybindings act without opening a window: a screenshot is written, a
# wallpaper is replaced, the volume moves. The only evidence is a file in a
# directory you are not looking at - and a *failure* is completely invisible,
# because a keybinding has no terminal to print to. i3 discards the output of
# everything it execs. So anything bound to a key that does not put a window on
# screen reports through here instead.
#
#   notify.sh [options] SUMMARY [BODY]
#
#   -u low|normal|critical  urgency. critical never expires - see dunstrc.
#   -i ICON                 an icon name from the theme, or a path to an image
#                           (a screenshot notification shows the shot itself)
#   -t TAG                  replace the last notification carrying this tag
#                           rather than stacking a new one under it
#   -p 0-100                draw dunst's progress bar at this value
#   -T MS                   expire after this many milliseconds
#   -a NAME                 app name, as the daemon sees it (default: i3)
#   -A KEY=Label            offer an action. Waits for the notification to be
#                           closed and prints the chosen key on stdout - middle
#                           click is `do_action` in dunstrc.
#   -w                      wait for the daemon to answer before sending
#
# The tag is what makes this usable from a key you hold down. Ten volume steps
# with no tag are ten notifications stacking down the screen, each outliving
# the value it reported; with one they are a single popup counting up. dunst
# implements it as a hint, so it costs nothing anywhere else.
#
# Exit status is 0 whether or not the message was delivered. A screenshot that
# was taken has been taken, even if nothing could say so, and a keybinding must
# never be reported as failed because a notification daemon is not running.

set -uo pipefail

URGENCY=normal
ICON=""
TAG=""
VALUE=""
TIMEOUT=""
APP=i3
WAIT=0
ACTIONS=()

while (( $# )); do
    case "$1" in
        -u) shift; URGENCY="${1:-normal}" ;;
        -i) shift; ICON="${1:-}" ;;
        -t) shift; TAG="${1:-}" ;;
        -p) shift; VALUE="${1:-}" ;;
        -T) shift; TIMEOUT="${1:-}" ;;
        -a) shift; APP="${1:-i3}" ;;
        -A) shift; [[ -n "${1:-}" ]] && ACTIONS+=(--action "$1") ;;
        -w) WAIT=1 ;;
        -h|--help)
            awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
            exit 0 ;;
        --) shift; break ;;
        -*) printf 'notify: unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
        *)  break ;;
    esac
    shift
done

SUMMARY="${1:-}"
BODY="${2:-}"
[[ -z "$SUMMARY" ]] && { printf 'notify: nothing to say (try --help)\n' >&2; exit 2; }

# No libnotify, or a headless run: say it on stderr and report success anyway.
if ! command -v notify-send >/dev/null; then
    printf '%s: %s\n' "$SUMMARY" "$BODY" >&2
    exit 0
fi

# --- wait for the daemon ----------------------------------------------------
#
# Only needed on one path: theme_init.sh restarts dunst when the palette
# changes, and a notification sent into that window goes to the instance that
# is exiting and is simply lost. Any dunstctl call that gets an answer means
# the new one owns the bus name; it also D-Bus-activates dunst if nothing is
# running, which is the same thing notify-send would do a moment later.
if (( WAIT )) && command -v dunstctl >/dev/null; then
    for _ in $(seq 20); do
        dunstctl is-paused >/dev/null 2>&1 && break
        sleep 0.05
    done
fi

ARGS=( --app-name "$APP" --urgency "$URGENCY" )

# A path that no longer exists (a screenshot deleted between taking it and
# reading it back) would leave dunst logging a load failure per notification.
if [[ -n "$ICON" ]]; then
    if [[ "$ICON" == */* ]]; then
        [[ -f "$ICON" ]] && ARGS+=( --icon "$ICON" )
    else
        ARGS+=( --icon "$ICON" )
    fi
fi

[[ -n "$TAG" ]]     && ARGS+=( --hint "string:x-dunst-stack-tag:$TAG" )
[[ -n "$TIMEOUT" ]] && ARGS+=( --expire-time "$TIMEOUT" )

# The progress bar is drawn from an int hint, and dunst draws one for any value
# it is given - including a negative or a 4000, which is how a percentage that
# was never parsed ends up as a bar across the whole screen.
if [[ -n "$VALUE" ]]; then
    if [[ "$VALUE" =~ ^-?[0-9]+$ ]]; then
        (( VALUE < 0 ))   && VALUE=0
        (( VALUE > 100 )) && VALUE=100
        ARGS+=( --hint "int:value:$VALUE" )
    else
        printf 'notify: -p wants a number, got: %s\n' "$VALUE" >&2
    fi
fi

# An empty body is left off rather than passed as "": dunst formats every
# notification as "<b>%s</b>\n%b", so an empty second argument is a blank line
# of padding under the title of every notification that is only a title.
TEXT=( "$SUMMARY" )
[[ -n "$BODY" ]] && TEXT+=( "$BODY" )

# --action implies --wait: notify-send stays alive until the notification is
# closed and prints the key of whatever was picked. That is the point when
# there are actions, and would be a process sitting around for the timeout
# when there are none.
#
# stderr is deliberately not swallowed. From a keybinding it goes nowhere
# anyway, and from a terminal - which is where you are when you are working out
# why nothing is appearing - it is the only thing that says what went wrong.
notify-send "${ARGS[@]}" "${ACTIONS[@]}" -- "${TEXT[@]}"

exit 0
