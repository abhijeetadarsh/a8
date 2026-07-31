#!/usr/bin/env bash
#
# monitors.sh - work out what is plugged in, arrange it, and write the i3
# workspace -> output assignments for it.
#
#   monitors.sh            detect, arrange left-to-right, write monitors.conf
#   monitors.sh --no-apply  write monitors.conf but do not touch xrandr
#   monitors.sh --print     show what it would do
#   monitors.sh --modes     list the resolutions each screen supports
#
# i3 runs this before it reads monitors.conf, and $mod+Shift+m re-runs it when
# you plug a screen in.
#
# Position, primary and mode are three separate things:
#
#   position   where a screen sits left-to-right. This is the order of the
#              lines in the config file, and it is what decides which
#              workspaces land on which screen.
#   primary    xrandr's --primary flag. One output. It does not move a screen
#              and it does not change the workspace split; it is what apps mean
#              when they ask for "the main screen".
#   mode       resolution and refresh rate, per output.
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

# Where the layout is described. One output per line, in left-to-right order:
#
#     # output   resolution   rate   flags
#     HDMI-1     2560x1440    144    primary
#     eDP-1      1920x1080    60
#
# Only the output name is required. Resolution may be "1920x1080" or
# "1920x1080@60"; use "-" or "auto" to keep the screen's preferred mode and
# still set a rate or a flag. The only flag is "primary".
#
# A bare list of names is still valid, which is what this file used to be:
#
#     printf 'HDMI-1\neDP-1\n' > ~/.config/i3/monitor-order
#
# Outputs listed here but not plugged in are skipped, and anything connected
# but not listed is appended on the right, so one file covers docked and
# undocked. Delete it to go back to auto-detection.
ORDER_FILE="$HOME/.config/i3/monitor-order"

APPLY=1
PRINT=0
LIST_MODES=0

declare -A MODE=()          # output -> WxH the user asked for
declare -A RATE=()          # output -> refresh rate the user asked for
PRIMARY_WANT=""             # output the user wants as xrandr --primary

# --mode/--rate take OUT=VALUE. The resolution may carry the rate with it, so
# "--mode HDMI-1=2560x1440@144" and "--mode HDMI-1=2560x1440 --rate HDMI-1=144"
# mean the same thing.
set_mode() {
    local out="${1%%=*}" val="${1#*=}"
    [[ "$1" == *=* && -n "$out" ]] || { printf 'monitors: expected OUT=MODE, got: %s\n' "$1" >&2; exit 1; }
    if [[ "$val" == *@* ]]; then
        RATE["$out"]="${val#*@}"
        val="${val%@*}"
    fi
    [[ -n "$val" && "$val" != auto && "$val" != - ]] && MODE["$out"]="$val"
    return 0
}

set_rate() {
    local out="${1%%=*}" val="${1#*=}"
    [[ "$1" == *=* && -n "$out" ]] || { printf 'monitors: expected OUT=RATE, got: %s\n' "$1" >&2; exit 1; }
    RATE["$out"]="$val"
}

while (( $# )); do
    case "$1" in
        --no-apply) APPLY=0 ;;
        --print)    PRINT=1; APPLY=0 ;;
        --modes)    LIST_MODES=1; APPLY=0 ;;
        --order)    shift; ORDER_OVERRIDE="${1:-}" ;;
        --primary)  shift; PRIMARY_WANT="${1:-}" ;;
        --mode)     shift; set_mode "${1:-}" ;;
        --rate)     shift; set_rate "${1:-}" ;;
        --help|-h)
            cat <<EOF
usage: $0 [--print] [--no-apply] [--modes]
          [--order "OUT1 OUT2"] [--primary OUT]
          [--mode OUT=WxH[@RATE]] [--rate OUT=RATE]

  --print    show the layout it would write, change nothing
  --no-apply write monitors.conf but do not run xrandr
  --modes    list the resolutions and rates each screen supports
  --order    left-to-right monitor order for this run only,
             e.g. --order "HDMI-1 eDP-1"
  --primary  which output gets xrandr's --primary flag. Independent of
             position: it does not move a screen or change the workspace split
  --mode     resolution for one output, e.g. --mode HDMI-1=2560x1440@144
  --rate     refresh rate for one output, e.g. --rate HDMI-1=144

Anything not given on the command line comes from $ORDER_FILE,
and anything that file does not say is auto-detected. A mode the screen
does not support is refused, with its supported modes listed, and that
screen falls back to its preferred one.

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

# Snapshot what the command line set, before the config file is read. The file
# fills in only what was not given here.
declare -A CLI_MODE=() CLI_RATE=()
for k in "${!MODE[@]}";  do CLI_MODE["$k"]=1; done
for k in "${!RATE[@]}";  do CLI_RATE["$k"]=1; done
CLI_PRIMARY="$PRIMARY_WANT"

command -v xrandr >/dev/null || { printf 'monitors: xrandr not found\n' >&2; exit 1; }

# --- 1. what is connected ---------------------------------------------------

XQUERY="$(xrandr --query)"

mapfile -t CONNECTED < <(printf '%s\n' "$XQUERY" | awk '/ connected/ {print $1}')

if (( ${#CONNECTED[@]} == 0 )); then
    printf 'monitors: no connected outputs\n' >&2
    exit 1
fi

# --- 1a. what each screen can actually do ------------------------------------
#
# xrandr --query prints an indented mode line per supported resolution:
#
#     HDMI-1 connected 2560x1440+0+0 ...
#        2560x1440    143.86*+ 120.00   60.00
#
# AVAIL[out] collects those as "WxH:rate,rate WxH:rate,..." so a requested
# mode can be checked before it is handed to xrandr. Asking for a mode a
# screen does not have is how you end up staring at a black display.

declare -A AVAIL=()
while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z0-9_.-]+)\ (dis)?connected ]]; then
        cur="${BASH_REMATCH[1]}"
        continue
    fi
    [[ -n "${cur:-}" ]] || continue
    # Mode lines are indented; rates carry * (current) and + (preferred).
    if [[ "$line" =~ ^[[:space:]]+([0-9]+x[0-9]+)[[:space:]]+(.*)$ ]]; then
        res="${BASH_REMATCH[1]}"
        rates="${BASH_REMATCH[2]//[*+]/}"
        rates="$(printf '%s' "$rates" | tr -s ' ' ',' | sed 's/^,//;s/,$//')"
        AVAIL["$cur"]+="${res}:${rates} "
    fi
done < <(printf '%s\n' "$XQUERY")

if (( LIST_MODES )); then
    for o in "${CONNECTED[@]}"; do
        printf '%s\n' "$o"
        for entry in ${AVAIL[$o]:-}; do
            printf '  %-12s %s\n' "${entry%%:*}" "${entry#*:}"
        done
    done
    exit 0
fi

# Does this output support this resolution? Prints nothing, sets the exit code.
has_mode() {
    local out="$1" want="$2" entry
    for entry in ${AVAIL[$out]:-}; do
        [[ "${entry%%:*}" == "$want" ]] && return 0
    done
    return 1
}

# Does this resolution on this output offer (approximately) this rate?
# xrandr reports 143.86 where a user writes 144, so compare rounded.
has_rate() {
    local out="$1" res="$2" want="$3" entry r
    want="$(printf '%.0f' "$want" 2>/dev/null)" || return 1
    for entry in ${AVAIL[$out]:-}; do
        [[ "${entry%%:*}" == "$res" ]] || continue
        for r in ${entry#*:}; do
            r="${r//,/ }"
            for one in $r; do
                [[ "$(printf '%.0f' "$one" 2>/dev/null)" == "$want" ]] && return 0
            done
        done
    done
    return 1
}

# What resolution will this output actually run at, requested or preferred?
# Needed to check a rate when only --rate was given.
current_res() {
    local out="$1"
    if [[ -n "${MODE[$out]:-}" ]]; then
        printf '%s' "${MODE[$out]}"
        return
    fi
    # The preferred mode is the one xrandr marks with '+'.
    printf '%s\n' "$XQUERY" | awk -v o="$out" '
        $1 == o { found = 1; next }
        found && /^[A-Za-z0-9_.-]+ (dis)?connected/ { exit }
        found && /\+/ && $1 ~ /^[0-9]+x[0-9]+$/ { print $1; exit }
    '
}

# --- 1b. what order they go in ----------------------------------------------

is_connected() {
    local o
    for o in "${CONNECTED[@]}"; do [[ "$o" == "$1" ]] && return 0; done
    return 1
}

# The file is read for its per-output settings even when --order is given.
# --order overrides the *ordering*, nothing else: dropping the resolutions and
# the primary along with it is not what "put HDMI-1 on the left for a moment"
# should mean, and it is the same per-setting rule --mode and --rate follow.
FILE_ORDER=()
if [[ -f "$ORDER_FILE" ]]; then
    while read -r line; do
        line="${line%%#*}"
        # Fields, not one squashed token: a line may carry a mode and flags.
        read -r -a fields <<< "$line"
        (( ${#fields[@]} )) || continue

        out="${fields[0]}"
        FILE_ORDER+=("$out")

        # The command line overrides the file, per setting rather than per
        # line: --rate on its own must not throw away the resolution the file
        # gives for the same output. CLI_* records what was set before the
        # file was read, which is exactly what must not be overwritten.
        for field in "${fields[@]:1}"; do
            case "$field" in
                primary)
                    [[ -z "$CLI_PRIMARY" ]] && PRIMARY_WANT="$out" ;;
                auto|-)
                    ;;
                [0-9]*x[0-9]*)
                    # A file entry may be WxH@rate; honour each half separately.
                    file_res="${field%@*}"
                    [[ -z "${CLI_MODE[$out]:-}" ]] && MODE["$out"]="$file_res"
                    if [[ "$field" == *@* && -z "${CLI_RATE[$out]:-}" ]]; then
                        RATE["$out"]="${field#*@}"
                    fi ;;
                [0-9]*)
                    [[ -z "${CLI_RATE[$out]:-}" ]] && RATE["$out"]="$field" ;;
                *)
                    printf 'monitors: %s: ignoring unknown field "%s"\n' "$out" "$field" >&2 ;;
            esac
        done
    done < "$ORDER_FILE"
fi

WANTED=()
if [[ -n "${ORDER_OVERRIDE:-}" ]]; then
    read -r -a WANTED <<< "$ORDER_OVERRIDE"
else
    WANTED=("${FILE_ORDER[@]:-}")
fi

ORDERED=()
for o in "${WANTED[@]:-}"; do
    # Silently skip what is in the list but not plugged in: that is the whole
    # point of the file surviving an undock.
    [[ -n "$o" ]] && is_connected "$o" || continue

    # A name listed twice would be placed --right-of itself and would collect
    # two sets of workspaces. First mention wins; say so, because a repeat is
    # a typo rather than an intention.
    dup=0
    for p in "${ORDERED[@]:-}"; do [[ "$p" == "$o" ]] && { dup=1; break; }; done
    if (( dup )); then
        printf 'monitors: %s is listed more than once, ignoring the repeat\n' "$o" >&2
        continue
    fi
    ORDERED+=("$o")
done

# Anything connected that the order file did not mention goes on the right.
for o in "${CONNECTED[@]}"; do
    seen=0
    for p in "${ORDERED[@]:-}"; do [[ "$p" == "$o" ]] && { seen=1; break; }; done
    (( seen )) || ORDERED+=("$o")
done

if (( ${#WANTED[@]} == 0 )); then
    # No explicit order. The internal panel is the natural anchor - it is the
    # one that is always there - so it goes leftmost, then xrandr's own order.
    ANCHOR=""
    for o in "${CONNECTED[@]}"; do
        case "$o" in eDP*|LVDS*) ANCHOR="$o"; break ;; esac
    done
    [[ -z "$ANCHOR" ]] && ANCHOR="$(printf '%s\n' "$XQUERY" | awk '/ connected primary/ {print $1; exit}')"
    [[ -z "$ANCHOR" ]] && ANCHOR="${CONNECTED[0]}"

    ORDERED=("$ANCHOR")
    for o in "${CONNECTED[@]}"; do
        [[ "$o" == "$ANCHOR" ]] || ORDERED+=("$o")
    done
fi

# --- 1c. which one is primary ------------------------------------------------
#
# Position and primary are independent. The leftmost screen is only the
# default, for when nothing says otherwise - naming one explicitly does not
# move it, and does not change which workspaces it gets.

if [[ -n "$PRIMARY_WANT" ]] && ! is_connected "$PRIMARY_WANT"; then
    printf 'monitors: %s is not connected, leaving primary on %s\n' \
        "$PRIMARY_WANT" "${ORDERED[0]}" >&2
    PRIMARY_WANT=""
fi

PRIMARY="${PRIMARY_WANT:-${ORDERED[0]}}"
SECONDARY=()
for o in "${ORDERED[@]}"; do
    [[ "$o" == "$PRIMARY" ]] || SECONDARY+=("$o")
done

# --- 1d. refuse modes the hardware does not have -----------------------------
#
# xrandr fails quietly when it cannot set a mode, which leaves a screen dark
# with nothing on stdout to explain it. Check first, say what went wrong, and
# fall back to the preferred mode rather than to a black display.

for o in "${ORDERED[@]}"; do
    if [[ -n "${MODE[$o]:-}" ]] && ! has_mode "$o" "${MODE[$o]}"; then
        printf 'monitors: %s cannot do %s - using its preferred mode\n' "$o" "${MODE[$o]}" >&2
        printf 'monitors:   it supports: %s\n' "$(
            for e in ${AVAIL[$o]:-}; do printf '%s ' "${e%%:*}"; done
        )" >&2
        unset 'MODE[$o]'
    fi

    if [[ -n "${RATE[$o]:-}" ]]; then
        res="$(current_res "$o")"
        if [[ -n "$res" ]] && ! has_rate "$o" "$res" "${RATE[$o]}"; then
            printf 'monitors: %s cannot do %s Hz at %s - using its default rate\n' \
                "$o" "${RATE[$o]}" "$res" >&2
            printf 'monitors:   at %s it offers: %s\n' "$res" "$(
                for e in ${AVAIL[$o]:-}; do
                    [[ "${e%%:*}" == "$res" ]] && printf '%s' "${e#*:}"
                done
            )" >&2
            unset 'RATE[$o]'
        fi

        # A rate on its own has to be pinned to an explicit resolution.
        #
        # `--output X --auto --rate 120` is accepted by xrandr, exits 0, and
        # changes nothing: --auto picks the preferred mode *and* its default
        # rate, and the --rate beside it is ignored. Only `--mode WxH --rate R`
        # actually switches the rate. So resolve the preferred resolution here
        # and ask for it by name.
        if [[ -n "${RATE[$o]:-}" && -z "${MODE[$o]:-}" ]]; then
            if [[ -n "$res" ]]; then
                MODE["$o"]="$res"
            else
                printf 'monitors: %s: cannot tell which resolution it prefers, dropping the %s Hz request\n' \
                    "$o" "${RATE[$o]}" >&2
                unset 'RATE[$o]'
            fi
        fi
    fi
done

# --- 2. how the ten workspaces are split ------------------------------------
#
# By position, left to right - not by which screen is primary. The number keys
# should walk across the desk in the order the screens physically sit.
#
# One monitor  -> all ten on it.
# Two monitors -> 1-5 on the left, 6-10 on the right, so the number keys
#                 split down the middle and $mod+6 always means "other screen".
# Three or more-> spread as evenly as the ten divide.

declare -A ASSIGN=()   # workspace number -> the one output it belongs to

if (( ${#ORDERED[@]} == 1 )); then
    for ws in {1..10}; do ASSIGN[$ws]="${ORDERED[0]}"; done
else
    ALL=("${ORDERED[@]}")
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

# How a screen will be driven, for the human-readable output.
describe() {
    local o="$1" res="${MODE[$o]:-}" rate="${RATE[$o]:-}"
    [[ -z "$res" ]] && res="$(current_res "$o") (preferred)"
    [[ -n "$rate" ]] && res+=" @ ${rate}Hz"
    printf '%s' "$res"
}

# What is on screen right now, straight from xrandr, as
# "xoffset<TAB>output<TAB>WxH<TAB>rate" sorted left to right by x offset.
#
# This is deliberately not derived from the plan. --print used to show only
# what it *would* do, which reads as a statement about the screens in front of
# you - so after a one-off `--order`, the plan and the desk disagreed and the
# output gave no hint which was which.
current_layout() {
    local o geo res x rate
    for o in "${CONNECTED[@]}"; do
        geo="$(printf '%s\n' "$XQUERY" | awk -v o="$o" '
            $1 == o { for (i = 3; i <= NF; i++)
                          if ($i ~ /^[0-9]+x[0-9]+\+-?[0-9]+\+-?[0-9]+$/) { print $i; exit } }')"
        [[ -n "$geo" ]] || continue          # connected but not enabled
        res="${geo%%+*}"
        x="${geo#*+}"; x="${x%%+*}"
        # The active rate is the one xrandr marks with '*'.
        rate="$(printf '%s\n' "$XQUERY" | awk -v o="$o" '
            $1 == o { f = 1; next }
            f && /^[A-Za-z0-9_.-]+ (dis)?connected/ { exit }
            f && /\*/ { for (i = 2; i <= NF; i++)
                            if ($i ~ /\*/) { gsub(/[*+]/, "", $i); print $i; exit } }')"
        printf '%s\t%s\t%s\t%s\n' "$x" "$o" "$res" "${rate:-?}"
    done | sort -n
}

current_primary() {
    printf '%s\n' "$XQUERY" | awk '/ connected primary/ { print $1; exit }'
}

if (( PRINT )); then
    if [[ -n "${ORDER_OVERRIDE:-}" ]]; then
        src="the --order given on the command line"
    elif [[ -f "$ORDER_FILE" ]]; then
        src="$ORDER_FILE"
    else
        src="auto-detection (no $ORDER_FILE)"
    fi

    printf 'would apply, from %s:\n' "$src"
    printf '  left to right: %s\n' "${ORDERED[*]}"
    printf '  primary:       %s\n' "$PRIMARY"
    for o in "${ORDERED[@]}"; do
        printf '    %-10s %s%s\n' "$o" "$(describe "$o")" \
            "$([[ "$o" == "$PRIMARY" ]] && printf '   [primary]')"
    done
    for ws in {1..10}; do printf '    ws %-2s -> %s\n' "$ws" "${ASSIGN[$ws]}"; done

    now_order=()
    while IFS=$'\t' read -r x o res rate; do
        now_order+=("$o")
        now_desc[${#now_order[@]}]="$(printf '%-10s %s @ %sHz' "$o" "$res" "$rate")"
    done < <(current_layout)

    printf '\non screen now:\n'
    printf '  left to right: %s\n' "${now_order[*]}"
    printf '  primary:       %s\n' "$(current_primary)"
    for i in "${!now_order[@]}"; do
        printf '    %s%s\n' "${now_desc[$((i + 1))]}" \
            "$([[ "${now_order[$i]}" == "$(current_primary)" ]] && printf '   [primary]')"
    done

    if [[ "${now_order[*]}" != "${ORDERED[*]}" || "$(current_primary)" != "$PRIMARY" ]]; then
        printf '\nThese differ. What is on screen came from an earlier run;\n'
        printf 'the plan above is what the next i3 reload will put back.\n'
        printf 'To keep an arrangement, put it in %s.\n' "$ORDER_FILE"
    fi
    exit 0
fi

# --- 3. arrange them --------------------------------------------------------

if (( APPLY )); then
    args=()
    prev=""
    for o in "${ORDERED[@]}"; do
        args+=( --output "$o" )
        # --mode and --auto are mutually exclusive; --auto picks the preferred
        # mode, which is what we want whenever nothing was asked for.
        if [[ -n "${MODE[$o]:-}" ]]; then
            args+=( --mode "${MODE[$o]}" )
        else
            args+=( --auto )
        fi
        [[ -n "${RATE[$o]:-}" ]] && args+=( --rate "${RATE[$o]}" )
        [[ "$o" == "$PRIMARY" ]] && args+=( --primary )
        # Position is the order of ORDERED, independent of which is primary.
        [[ -n "$prev" ]] && args+=( --right-of "$prev" )
        prev="$o"
    done
    # Switch off anything that is no longer plugged in, otherwise i3 keeps
    # showing workspaces on a monitor that is not there.
    while read -r o; do
        args+=( --output "$o" --off )
    done < <(printf '%s\n' "$XQUERY" | awk '/ disconnected/ && / [0-9]+x[0-9]+\+/ {print $1}')

    if ! xrandr "${args[@]}" 2>/dev/null; then
        printf 'monitors: xrandr refused the layout, retrying with preferred modes\n' >&2
        # Drop every mode and rate and try again. A layout with the wrong
        # refresh rate beats a session with no working screen.
        args=()
        prev=""
        for o in "${ORDERED[@]}"; do
            args+=( --output "$o" --auto )
            [[ "$o" == "$PRIMARY" ]] && args+=( --primary )
            [[ -n "$prev" ]] && args+=( --right-of "$prev" )
            prev="$o"
        done
        xrandr "${args[@]}" 2>/dev/null ||
            printf 'monitors: xrandr refused that too - leaving the screens alone\n' >&2
    fi
fi

# --- 4. write the i3 include ------------------------------------------------

mkdir -p "$(dirname "$OUT")"
{
    printf '# generated by monitors.sh - re-run it after plugging a screen in\n'
    printf '# %s connected: %s\n' "${#CONNECTED[@]}" "${CONNECTED[*]}"
    printf '# left to right: %s\n' "${ORDERED[*]}"
    for o in "${ORDERED[@]}"; do
        printf '#   %-10s %s\n' "$o" "$(describe "$o")"
    done
    printf '\n'
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
