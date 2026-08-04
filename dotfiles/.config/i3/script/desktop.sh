#!/usr/bin/env bash
#
# desktop.sh - the square at the left of the bar: show the desktop, on every
# monitor at once, the way Win+D does on Windows.
#
#   desktop.sh toggle       show the desktop everywhere, or put everything back
#   desktop.sh show         one direction only
#   desktop.sh hide
#   desktop.sh watch [OUT]  what the bar draws - one instance per bar, tailing
#                           i3. OUT defaults to $MONITOR, which polybar sets.
#   desktop.sh guard        move away anything that opens on a desktop
#                           workspace. Started once, by i3's exec_always.
#   desktop.sh status       print the square once and exit
#
# Bound to $mod+Shift+d, and to a left click on the square itself.
#
# An empty workspace *is* the desktop. The wallpaper is painted on the root
# window, so a workspace with nothing on it shows it, and every window keeps
# its place in the layout it was already in - nothing is minimised, so nothing
# has to be restored, and going back is one workspace switch.
#
# One workspace per monitor, because an i3 workspace lives on exactly one
# output and each output shows exactly one workspace at a time. "All monitors"
# is therefore N workspace switches, sent as a single i3 command so the screens
# change together rather than one after the other.
#
# They are named 0:d1, 0:d2 ... by monitor, left to right. The leading `0:`
# gives them workspace number 0, which is what puts them to the left of
# workspace 1 in i3's ordering - and the number is the only reason for the
# name, because the bar never shows it (see below).
#
# Why the square is a polybar module and not just that workspace's button:
# i3 deletes an empty workspace the moment you look away from it, so the button
# would exist only while you are already looking at the desktop - the opposite
# of a button that is always there. [module/desktop] is drawn by the bar
# itself, so it is there whether or not the workspace is. The workspace's own
# button is mapped to an empty icon in modules.ini, and polybar draws nothing
# at all for an empty label, so the two never both appear.
#
# Why a guard process rather than a config rule: i3 has no "this workspace
# takes no windows". `for_window` and `assign` match the window, not where it
# is going, and neither can say "not here". So a subscriber watches for windows
# appearing on a desktop workspace and moves them to the workspace that monitor
# came from, then follows them there - opening something from the desktop
# should take you to it, which is what Windows does too.

set -uo pipefail

# `0:` is load-bearing (workspace number 0, sorts first); `d` is just a name.
PREFIX="0:d"
STATE="${XDG_RUNTIME_DIR:-/tmp}/i3-desktop-$USER"
COLORS="$HOME/.config/polybar/shades/color/out.ini"
GLYPH="${DESKTOP_GLYPH:-▪}"

mkdir -p "$STATE" 2>/dev/null

command -v jq >/dev/null || {
    printf 'desktop.sh: jq is not installed - it is how this reads i3\n' >&2
    exit 1
}

# --- what is where ----------------------------------------------------------

# Active outputs, left to right. Sorted by x rather than taken in the order i3
# lists them: the position in this list is what names each monitor's workspace,
# so it has to come out the same on every call, in every process - the bar's
# watcher and the click that switches must agree on which square is which.
outputs() {
    i3-msg -t get_outputs 2>/dev/null |
        jq -r '[.[] | select(.active)] | sort_by(.rect.x) | .[].name'
}

# output<TAB>visible-workspace, for every output at once.
visible_map() {
    i3-msg -t get_workspaces 2>/dev/null |
        jq -r '.[] | select(.visible) | "\(.output)\t\(.name)"'
}

focused_output() {
    i3-msg -t get_workspaces 2>/dev/null |
        jq -r '.[] | select(.focused) | .output' | head -1
}

visible_on() {
    i3-msg -t get_workspaces 2>/dev/null |
        jq -r --arg o "$1" '.[] | select(.visible and .output == $o) | .name' | head -1
}

is_desktop() { [[ "$1" == "$PREFIX"* ]]; }

# --- switching --------------------------------------------------------------

# The workspace this output goes back to: where it was when the desktop was
# shown, or - if that was never recorded, which is the guard evicting a window
# from a desktop workspace someone reached another way - the lowest-numbered
# workspace it already has, and failing that workspace 1.
restore_target() {
    local out="$1" saved="" low
    [[ -r "$STATE/$out" ]] && saved="$(<"$STATE/$out")"
    if [[ -n "$saved" ]] && ! is_desktop "$saved"; then
        printf '%s' "$saved"
        return
    fi
    low="$(i3-msg -t get_workspaces 2>/dev/null |
        jq -r --arg o "$out" --arg p "$PREFIX" '
            [.[] | select(.output == $o and ((.name | startswith($p)) | not))]
            | sort_by(.num) | .[0].name // empty')"
    printf '%s' "${low:-1}"
}

show() {
    local -a outs=()
    local -A vis=()
    local i out cur target cmd="" focused
    mapfile -t outs < <(outputs)
    (( ${#outs[@]} )) || return 0
    while IFS=$'\t' read -r out cur; do vis[$out]="$cur"; done < <(visible_map)
    focused="$(focused_output)"

    for i in "${!outs[@]}"; do
        out="${outs[$i]}"
        target="$PREFIX$(( i + 1 ))"
        cur="${vis[$out]:-}"
        [[ "$cur" == "$target" ]] && continue
        # Where to come back to. Written before the switch, because after it
        # the only workspace this output has is the empty one.
        [[ -n "$cur" ]] && ! is_desktop "$cur" && printf '%s\n' "$cur" > "$STATE/$out"
        cmd+="focus output $out; workspace $target; "
    done

    [[ -n "$cmd" ]] || return 0
    # Focus lands back where it was, so the desktop is shown *at* the monitor
    # you were using rather than moving you to the last one in the list.
    [[ -n "$focused" ]] && cmd+="focus output $focused"
    i3-msg -q "${cmd% }" >/dev/null
}

hide() {
    local -a outs=()
    local -A vis=()
    local i out cur target cmd="" focused
    mapfile -t outs < <(outputs)
    (( ${#outs[@]} )) || return 0
    while IFS=$'\t' read -r out cur; do vis[$out]="$cur"; done < <(visible_map)
    focused="$(focused_output)"

    for i in "${!outs[@]}"; do
        out="${outs[$i]}"
        cur="${vis[$out]:-}"
        is_desktop "$cur" || continue
        target="$(restore_target "$out")"
        cmd+="focus output $out; workspace $target; "
    done

    [[ -n "$cmd" ]] || return 0
    [[ -n "$focused" ]] && cmd+="focus output $focused"
    i3-msg -q "${cmd% }" >/dev/null
}

# Toggle on the state of the whole desk, not of one monitor: the square is one
# button that means one thing, and half a desktop is not a state worth having.
toggle() {
    local -a outs=()
    local -A vis=()
    local i out all=1
    mapfile -t outs < <(outputs)
    (( ${#outs[@]} )) || return 0
    while IFS=$'\t' read -r out cur; do vis[$out]="$cur"; done < <(visible_map)

    for i in "${!outs[@]}"; do
        [[ "${vis[${outs[$i]}]:-}" == "$PREFIX$(( i + 1 ))" ]] || { all=0; break; }
    done

    if (( all )); then hide; else show; fi
}

# --- the square -------------------------------------------------------------

# One colour out of the generated palette, so the square is themed with
# everything else. theme_init.sh restarts the bars after it rewrites this file,
# which restarts this script, which is when the new value is picked up.
color() {
    local v=""
    [[ -r "$COLORS" ]] &&
        v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(#[0-9A-Fa-f]\{3,8\}\).*/\1/p" \
            "$COLORS" | head -1)"
    printf '%s' "${v:-$2}"
}

# Deliberately the same shape as the workspace buttons next to it: one space of
# padding either side, accent behind it when it is the workspace you are on.
render() {
    local out="$1"
    if is_desktop "$(visible_on "$out")"; then
        printf '%%{B%s}%%{F%s} %s %%{F-}%%{B-}\n' \
            "$(color accent '#89a6d2')" "$(color background '#131618')" "$GLYPH"
    else
        printf '%%{F%s} %s %%{F-}\n' "$(color foreground-alt '#8a949e')" "$GLYPH"
    fi
}

# polybar starts one of these per bar and reads its stdout forever (tail = true
# in the module). Redrawing on i3's own events rather than on a timer is what
# makes the square light up in the same frame as the workspace switch.
watch() {
    local mon="${1:-${MONITOR:-}}"
    [[ -n "$mon" ]] || mon="$(focused_output)"
    [[ -n "$mon" ]] || return 1

    render "$mon"
    # `output` as well as `workspace`: plugging a screen in renumbers the
    # monitors, so this bar's square may now belong to a different workspace.
    i3-msg -t subscribe -m '["workspace","output"]' 2>/dev/null |
        while IFS= read -r _; do render "$mon"; done
}

# --- the guard --------------------------------------------------------------

# Existing desktop workspaces, as name<TAB>output. There is at most one per
# monitor and usually none at all: they exist only while being looked at.
desktop_workspaces() {
    i3-msg -t get_workspaces 2>/dev/null |
        jq -r --arg p "$PREFIX" '.[] | select(.name | startswith($p)) | "\(.name)\t\(.output)"'
}

windows_on() {
    i3-msg -t get_tree 2>/dev/null |
        jq -r --arg ws "$1" '
            [recurse(.nodes[]?, .floating_nodes[]?)
             | select(.type == "workspace" and .name == $ws)] | .[]
            | [recurse(.nodes[]?, .floating_nodes[]?)
               | select(.window != null)] | .[].id'
}

# Anything sitting on a desktop workspace goes to where that monitor came from,
# and the workspace follows, so the window you just opened is the one you are
# looking at. Moving a window raises another window event, which runs this
# again and finds nothing - that is the loop terminating, not spinning.
evict() {
    local ws out ids id target cmd
    while IFS=$'\t' read -r ws out; do
        ids="$(windows_on "$ws")"
        [[ -n "$ids" ]] || continue
        target="$(restore_target "$out")"
        cmd=""
        for id in $ids; do
            cmd+="[con_id=$id] move container to workspace $target; "
        done
        cmd+="workspace $target"
        i3-msg -q "$cmd" >/dev/null
    done < <(desktop_workspaces)
}

guard() {
    # One guard per session. i3 does not kill what it exec'd, so a restart
    # ($mod+Shift+r) runs exec_always again while the old one is still alive;
    # the lock is what makes the second one exit instead of doubling every
    # move. flock releases it when the holder dies, whatever kills it.
    exec 9>"$STATE/guard.lock"
    flock -n 9 || exit 0

    # A window can already be there: i3 restores its layout before this starts.
    evict

    i3-msg -t subscribe -m '["window"]' 2>/dev/null |
        jq --unbuffered -r 'select(.change == "new" or .change == "move") | "."' |
        while IFS= read -r _; do evict; done
}

case "${1:-toggle}" in
    toggle)  toggle ;;
    show)    show ;;
    hide)    hide ;;
    watch)   watch "${2:-}" ;;
    guard)   guard ;;
    status)  render "${2:-${MONITOR:-$(focused_output)}}" ;;
    --help|-h)
        awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
        ;;
    *)
        printf 'desktop: unknown action: %s (try --help)\n' "$1" >&2
        exit 2
        ;;
esac
