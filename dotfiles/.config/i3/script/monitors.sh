#!/usr/bin/env bash
#
# monitors.sh - work out what is plugged in, arrange it, and write the i3
# workspace -> output assignments for it.
#
#   monitors.sh            detect, arrange left-to-right, write monitors.conf
#   monitors.sh --no-apply  write monitors.conf but do not touch xrandr
#   monitors.sh --print     show what it would do
#
# i3 runs this before it reads monitors.conf, and $mod+Shift+m re-runs it when
# you plug a screen in.
#
# The generated file is a plain list of
#
#     workspace 1 output eDP-1
#
# lines, with exactly ONE output each. i3 accepts a fallback list here, but do
# not use it: when an output is left with no workspace, i3 picks the first
# workspace *assigned to that output* to fill it, and an assignment counts as
# matching if the output appears anywhere in its list. Writing
# "workspace 1 output eDP-1 HDMI-1" therefore makes workspace 1 a candidate for
# HDMI-1, and the external monitor ends up showing workspace 1, 2, 4... instead
# of 6.
#
# Fallbacks are not needed anyway: this file is regenerated on every i3 start
# and by $mod+Shift+m, so it always describes what is actually plugged in.

set -uo pipefail

OUT="$HOME/.config/i3/monitors.conf"

# Where you say which monitor comes first. One output name per line, in
# left-to-right order; blank lines and #comments ignored. Outputs listed here
# but not plugged in are skipped, and anything connected but not listed is
# appended on the right. Delete the file to go back to auto-detection.
#
#     printf 'HDMI-1\neDP-1\n' > ~/.config/i3/monitor-order
#     ~/.config/i3/script/monitors.sh
ORDER_FILE="$HOME/.config/i3/monitor-order"

APPLY=1
PRINT=0

while (( $# )); do
    case "$1" in
        --no-apply) APPLY=0 ;;
        --print)    PRINT=1; APPLY=0 ;;
        --order)    shift; ORDER_OVERRIDE="${1:-}" ;;
        --help|-h)
            cat <<EOF
usage: $0 [--print] [--no-apply] [--order "OUT1 OUT2"]

  --print    show the layout it would write, change nothing
  --no-apply write monitors.conf but do not run xrandr
  --order    left-to-right monitor order for this run only,
             e.g. --order "HDMI-1 eDP-1"

Order is taken from, in priority order:
  1. --order
  2. $ORDER_FILE
  3. auto: the internal panel first, then xrandr's order
EOF
            exit 0 ;;
        *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

command -v xrandr >/dev/null || { printf 'monitors: xrandr not found\n' >&2; exit 1; }

# --- 1. what is connected ---------------------------------------------------

mapfile -t CONNECTED < <(xrandr --query | awk '/ connected/ {print $1}')

if (( ${#CONNECTED[@]} == 0 )); then
    printf 'monitors: no connected outputs\n' >&2
    exit 1
fi

# --- 1b. what order they go in ----------------------------------------------

is_connected() {
    local o
    for o in "${CONNECTED[@]}"; do [[ "$o" == "$1" ]] && return 0; done
    return 1
}

WANTED=()
if [[ -n "${ORDER_OVERRIDE:-}" ]]; then
    read -r -a WANTED <<< "$ORDER_OVERRIDE"
elif [[ -f "$ORDER_FILE" ]]; then
    while read -r line; do
        line="${line%%#*}"; line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && WANTED+=("$line")
    done < "$ORDER_FILE"
fi

ORDERED=()
for o in "${WANTED[@]:-}"; do
    # Silently skip what is in the list but not plugged in: that is the whole
    # point of the file surviving an undock.
    [[ -n "$o" ]] && is_connected "$o" && ORDERED+=("$o")
done

# Anything connected that the order file did not mention goes on the right.
for o in "${CONNECTED[@]}"; do
    seen=0
    for p in "${ORDERED[@]:-}"; do [[ "$p" == "$o" ]] && { seen=1; break; }; done
    (( seen )) || ORDERED+=("$o")
done

if (( ${#WANTED[@]} == 0 )); then
    # No explicit order. The internal panel is the natural anchor - it is the
    # one that is always there - so it goes first, then xrandr's own order.
    PRIMARY=""
    for o in "${CONNECTED[@]}"; do
        case "$o" in eDP*|LVDS*) PRIMARY="$o"; break ;; esac
    done
    [[ -z "$PRIMARY" ]] && PRIMARY="$(xrandr --query | awk '/ connected primary/ {print $1; exit}')"
    [[ -z "$PRIMARY" ]] && PRIMARY="${CONNECTED[0]}"

    ORDERED=("$PRIMARY")
    for o in "${CONNECTED[@]}"; do
        [[ "$o" == "$PRIMARY" ]] || ORDERED+=("$o")
    done
fi

PRIMARY="${ORDERED[0]}"
SECONDARY=("${ORDERED[@]:1}")

# --- 2. how the ten workspaces are split ------------------------------------
#
# One monitor  -> all ten on it.
# Two monitors -> 1-5 on the primary, 6-10 on the second, so the number keys
#                 split down the middle and $mod+6 always means "other screen".
# Three or more-> spread as evenly as the ten divide.

declare -A ASSIGN=()   # workspace number -> ordered output preference list

if (( ${#SECONDARY[@]} == 0 )); then
    for ws in {1..10}; do ASSIGN[$ws]="$PRIMARY"; done
else
    ALL=("$PRIMARY" "${SECONDARY[@]}")
    n=${#ALL[@]}
    if (( n == 2 )); then
        for ws in {1..5};  do ASSIGN[$ws]="${ALL[0]}"; done
        for ws in {6..10}; do ASSIGN[$ws]="${ALL[1]}"; done
    else
        per=$(( (10 + n - 1) / n ))
        for ws in {1..10}; do
            idx=$(( (ws - 1) / per ))
            (( idx >= n )) && idx=$(( n - 1 ))
            ASSIGN[$ws]="${ALL[$idx]}"
        done
    fi
fi

if (( PRINT )); then
    printf 'primary:   %s\n' "$PRIMARY"
    printf 'secondary: %s\n' "${SECONDARY[*]:-none}"
    for ws in {1..10}; do printf '  ws %-2s -> %s\n' "$ws" "${ASSIGN[$ws]}"; done
    exit 0
fi

# --- 3. arrange them --------------------------------------------------------

if (( APPLY )); then
    args=( --output "$PRIMARY" --auto --primary )
    prev="$PRIMARY"
    for o in "${SECONDARY[@]}"; do
        args+=( --output "$o" --auto --right-of "$prev" )
        prev="$o"
    done
    # Switch off anything that is no longer plugged in, otherwise i3 keeps
    # showing workspaces on a monitor that is not there.
    while read -r o; do
        args+=( --output "$o" --off )
    done < <(xrandr --query | awk '/ disconnected/ && / [0-9]+x[0-9]+\+/ {print $1}')

    xrandr "${args[@]}" 2>/dev/null || printf 'monitors: xrandr refused the layout\n' >&2
fi

# --- 4. write the i3 include ------------------------------------------------

mkdir -p "$(dirname "$OUT")"
{
    printf '# generated by monitors.sh - re-run it after plugging a screen in\n'
    printf '# %s connected: %s\n\n' "${#CONNECTED[@]}" "${CONNECTED[*]}"
    printf 'set $primary %s\n' "$PRIMARY"
    printf 'set $secondary %s\n\n' "${SECONDARY[0]:-$PRIMARY}"
    for ws in {1..10}; do
        printf 'workspace %s output %s\n' "$ws" "${ASSIGN[$ws]}"
    done
} > "$OUT"

# --- 5. move workspaces that already exist ----------------------------------
#
# "workspace N output X" only decides where a workspace is put when it is
# *created*. Workspaces that already exist stay where they are - across an i3
# reload, an i3 restart, and across plugging a monitor in, which is precisely
# when you want them to move. So place them explicitly.

if command -v i3-msg >/dev/null && i3-msg -t get_version >/dev/null 2>&1; then
    assignments=""
    for ws in {1..10}; do
        assignments+="$ws=${ASSIGN[$ws]} "
    done

    # The map goes in argv, not on stdin: the heredoc below *is* stdin.
    python3 - "${CONNECTED[*]}" "$assignments" <<'PY'
import json, subprocess, sys

connected = set(sys.argv[1].split())
want = {}
for pair in sys.argv[2].split():
    if "=" in pair:
        n, out = pair.split("=", 1)
        want[n.strip()] = out.strip()

try:
    spaces = json.loads(subprocess.check_output(["i3-msg", "-t", "get_workspaces"]))
except Exception:
    sys.exit(0)

focused = next((w["name"] for w in spaces if w.get("focused")), None)
moved = 0

for w in spaces:
    num = str(w.get("num", ""))
    target = want.get(num)
    if not target or target not in connected:
        continue
    if w["output"] == target:
        continue
    subprocess.run(
        ["i3-msg", "-q", f'workspace number {num}; move workspace to output {target}'],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    moved += 1

if focused is not None:
    subprocess.run(["i3-msg", "-q", f'workspace {focused}'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

if moved:
    print(f"monitors: moved {moved} existing workspace(s) onto their assigned output")
PY
fi

printf 'monitors: %s -> %s\n' "${CONNECTED[*]}" "$OUT"
