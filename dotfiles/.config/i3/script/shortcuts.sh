#!/usr/bin/env bash
#
# shortcuts.sh - what the keys do, read from the file that decides what the
# keys do.
#
#   shortcuts.sh              print the table (what you get in a terminal)
#   shortcuts.sh --rofi       the searchable list ($mod+F1 uses this)
#   shortcuts.sh --list       force the table, even with no terminal
#   shortcuts.sh --config F   read some other i3 config
#   shortcuts.sh <word>       only lines matching <word>
#
# There is no second list of shortcuts to keep in step with the first one.
# A cheatsheet maintained by hand is wrong within a week - it says `$mod+p`
# for a key that was moved months ago, and it never mentions the binding added
# yesterday. This parses ~/.config/i3/config, so it cannot disagree with the
# keyboard: a binding that is not in the config is not on the list, and one
# that is, is.
#
# CLI or GUI, and why both:
#
#   - stdout is a terminal   -> print a table. You ran it in a shell; a popup
#                               stealing focus is not what that means.
#   - stdout is not          -> rofi, which is what i3's exec gives you. rofi
#                               is already installed, already themed from the
#                               wallpaper, and - the actual point - it filters
#                               as you type. "What was the screenshot key?" is
#                               answered by typing `shot`, which is a thing a
#                               static image of a keymap cannot do.
#
# The rofi list is a viewer: Enter closes it and runs nothing. It would be easy
# to make selecting a line execute the binding, and it would mean a help window
# in which the wrong keystroke can end your X session. Looking up a key must be
# safe to do in the middle of anything.
#
# ---------------------------------------------------------------------------
# Annotating the config
#
# Descriptions come from three places, in this order:
#
#   #:: Windows            a heading. Everything after it is in that group,
#                          until the next one.
#   #: close the window    the description of the binding on the *next* line.
#   #: $mod+d | launcher   same, but also states the key - for `bindcode`,
#                          where the config holds a raw keycode that means
#                          nothing to a reader.
#
# and failing all of those, the i3 command itself, tidied up. So a binding
# added without a comment still appears, described by what it does, rather
# than being silently missing from the help.
#
# Runs of bindings that differ only in a digit - the ten workspace keys, twice
# - are collapsed into one line automatically. Ten rows saying "workspace
# number 4" is not a cheatsheet, it is the config with extra steps.

set -uo pipefail

CONFIG="$HOME/.config/i3/config"
MODE=auto
FILTER=""

while (( $# )); do
    case "$1" in
        --rofi|-r)   MODE=rofi ;;
        --list|-l)   MODE=list ;;
        --config|-c) shift; CONFIG="${1:-}" ;;
        --help|-h)
            awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
            exit 0 ;;
        -*) printf 'shortcuts: unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
        *)  FILTER="$1" ;;
    esac
    shift
done

[[ -r "$CONFIG" ]] || { printf 'shortcuts: cannot read %s\n' "$CONFIG" >&2; exit 1; }

# stdout *or* stderr, not stdout alone. `keys | grep shot` from a terminal is
# an ordinary thing to type, and it takes stdout away without taking the
# terminal away - so testing stdout by itself answers "print or pop up?" with
# "pop up" for a command that is plainly being read as text. i3 hands its exec
# neither, which is the case rofi is for.
if [[ "$MODE" == auto ]]; then
    if [[ -t 1 || -t 2 ]]; then MODE=list; else MODE=rofi; fi
fi

# --- the parse --------------------------------------------------------------
#
# Emits one "group<TAB>key<TAB>description" record per binding, in config
# order, with the digit-runs already collapsed.

parse() {
    awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }

    # i3 substitutes its variables textually and so do we, so the list shows
    # the keys as i3 resolves them rather than as the file spells them.
    function expand(s,   v) {
        for (v in VAR) gsub("\\" v "\\>", VAR[v], s)
        return s
    }

    # Modifier names nobody says out loud. Mod4 is the key with the logo on it.
    function pretty(k) {
        gsub(/Mod4/, "Super", k)
        gsub(/Mod1/, "Alt", k)
        gsub(/comma/, ",", k)
        gsub(/period/, ".", k)
        gsub(/semicolon/, ";", k)
        gsub(/slash/, "/", k)
        gsub(/Return/, "Enter", k)
        gsub(/XF86Audio/, "", k)
        return k
    }

    # The fallback description: the i3 command, minus the boilerplate that is
    # the same on every line and tells the reader nothing.
    function describe(c) {
        c = trim(c)
        sub(/^exec[[:space:]]+--no-startup-id[[:space:]]+/, "", c)
        sub(/^exec[[:space:]]+/, "", c)
        # After the exec, because that is where the quotes are: i3 writes
        # `exec "..."`, not `"exec ..."`. And only when the whole of what is
        # left is quoted - stripping the ends unconditionally would turn
        # `mode "default"` into `mode "default`.
        if (c ~ /^".*"$/) { sub(/^"/, "", c); sub(/"$/, "", c) }
        sub(/^sh -c .*$/, "a shell command - see the config", c)
        gsub(/\$HOME\/\.config\/i3\/script\//, "", c)
        gsub(/\$HOME\/\.config\/polybar\/shades\//, "", c)
        gsub(/[[:space:]]+/, " ", c)
        if (length(c) > 58) c = substr(c, 1, 57) "…"
        return trim(c)
    }

    # Groups come out in the order they first appear in the config, not in the
    # order the bindings do: `mode "resize"` sits in the middle of the file and
    # would otherwise split the group around it into two headings with the same
    # name.
    function emit(g, k, d) {
        N++; G[N] = g; K[N] = k; D[N] = d
        if (!(g in GSEEN)) { GSEEN[g] = ++NG; GORDER[NG] = g }
    }

    function out(g, k, d) {
        M++; OG[M] = g; OK[M] = k; OD[M] = d
    }

    BEGIN { group = "Other" }

    # set $mod Mod4
    $1 == "set" && $2 ~ /^\$/ {
        val = $0
        sub(/^[[:space:]]*set[[:space:]]+\$[A-Za-z0-9_]+[[:space:]]+/, "", val)
        val = trim(val); sub(/^"/, "", val); sub(/"$/, "", val)
        VAR[$2] = val
        next
    }

    # #:: Group heading                (must be tested before #:)
    /^[[:space:]]*#::/ {
        g = trim(substr($0, index($0, "#::") + 3))
        if (g != "") group = g
        next
    }

    # #: description   or   #: key | description
    /^[[:space:]]*#:/ {
        d = trim(substr($0, index($0, "#:") + 2))
        if (index(d, "|")) {
            pkey = trim(substr(d, 1, index(d, "|") - 1))
            d    = trim(substr(d, index(d, "|") + 1))
        }
        pdesc = d
        next
    }

    # mode "resize" {   - a block. `bindsym $mod+r mode "resize"` is not one,
    # and does not reach here because it starts with bindsym.
    /^[[:space:]]*mode[[:space:]]+"/ && /\{[[:space:]]*$/ {
        modename = $0
        sub(/^[^"]*"/, "", modename); sub(/".*$/, "", modename)
        next
    }
    /^[[:space:]]*}[[:space:]]*$/ { modename = ""; next }

    $1 == "bindsym" || $1 == "bindcode" {
        iscode = ($1 == "bindcode")

        line = $0
        sub(/^[[:space:]]*(bindsym|bindcode)[[:space:]]+/, "", line)
        while (line ~ /^--[a-zA-Z-]+([[:space:]]|$)/) sub(/^--[a-zA-Z-]+[[:space:]]*/, "", line)

        keys = line; sub(/[[:space:]].*$/, "", keys)
        cmd  = line; sub(/^[^[:space:]]+[[:space:]]*/, "", cmd)

        # An overridden key goes through the same expansion as a real one, so
        # `#: $mod+d | ...` prints Super+d rather than the raw variable.
        key = pretty(expand((pkey != "") ? pkey : keys))
        # A raw keycode is a number, and a number is not a shortcut anyone can
        # read. Say so rather than printing "Super+40".
        if (iscode && pkey == "") key = key " (keycode)"

        # expand() on the command too: `workspace number $ws4` is a variable
        # the reader cannot resolve, and the digit it hides is the whole point
        # of the line.
        desc = (pdesc != "") ? pdesc : describe(expand(cmd))
        g = (modename != "") ? modename " mode" : group

        emit(g, key, desc)
        pdesc = ""; pkey = ""
        next
    }

    # Anything else that is not blank ends a pending description: a #: must sit
    # against the binding it describes, or it would drift onto an unrelated one.
    !/^[[:space:]]*(#|$)/ { pdesc = ""; pkey = "" }

    END {
        # Collapse runs that differ only in a digit - $mod+1..0 and friends.
        i = 1
        while (i <= N) {
            nk = K[i]; gsub(/[0-9]+/, "#", nk)
            nd = D[i]; gsub(/[0-9]+/, "#", nd)

            j = i
            while (j < N) {
                mk = K[j + 1]; gsub(/[0-9]+/, "#", mk)
                md = D[j + 1]; gsub(/[0-9]+/, "#", md)
                if (G[j + 1] != G[i] || mk != nk || md != nd) break
                j++
            }

            if (j > i) {
                # "Super+1 … 0": the second key with the shared prefix taken
                # off, because repeating "Super+" says nothing.
                tail = K[j]
                p = 0
                while (p < length(K[i]) && substr(K[i], p + 1, 1) == substr(tail, p + 1, 1)) p++
                if (p > 0) tail = substr(tail, p + 1)
                key = K[i] " … " tail

                # And the same for the description, when there is exactly one
                # number in it to put a range in.
                desc = D[i]
                if (gsub(/#/, "#", nd) == 1) {
                    a = D[i]; match(a, /[0-9]+/); a = substr(a, RSTART, RLENGTH)
                    b = D[j]; match(b, /[0-9]+/); b = substr(b, RSTART, RLENGTH)
                    desc = nd; sub(/#/, a "-" b, desc)
                }
                out(G[i], key, desc)
            } else {
                out(G[i], K[i], D[i])
            }
            i = j + 1
        }

        # Two keys that do the same thing are one line with both keys on it,
        # not two lines. i3 binds hjkl and the arrows to the same four commands
        # in resize mode, and Enter, Escape and $mod+r all leave it; listed
        # separately that is eleven rows for five things.
        for (i = 1; i <= M; i++) {
            id = OG[i] SUBSEP OD[i]
            if (id in ROW) {
                RK[ROW[id]] = RK[ROW[id]] " / " OK[i]
            } else {
                ROW[id] = ++R; RG[R] = OG[i]; RK[R] = OK[i]; RD[R] = OD[i]
            }
        }

        for (g = 1; g <= NG; g++)
            for (i = 1; i <= R; i++)
                if (RG[i] == GORDER[g])
                    printf "%s\t%s\t%s\n", RG[i], RK[i], RD[i]
    }
    ' "$CONFIG"
}

mapfile -t ROWS < <(parse)
(( ${#ROWS[@]} )) || { printf 'shortcuts: no bindings found in %s\n' "$CONFIG" >&2; exit 1; }

# Filter early, so the column widths fit what is actually shown.
if [[ -n "$FILTER" ]]; then
    mapfile -t ROWS < <(printf '%s\n' "${ROWS[@]}" | grep -i -- "$FILTER")
    (( ${#ROWS[@]} )) || { printf 'shortcuts: nothing matches "%s"\n' "$FILTER" >&2; exit 1; }
fi

# Widest key, so the descriptions line up in one column.
#
# Padded by hand rather than with printf's %-*s, which counts bytes: a key
# column containing "Super+1 … 0" is 11 characters and 13 bytes, and every row
# with an ellipsis in it would sit two columns short of the rest.
KW=0
for row in "${ROWS[@]}"; do
    k="${row#*$'\t'}"; k="${k%%$'\t'*}"
    (( ${#k} > KW )) && KW=${#k}
done

pad() { local n=$(( KW - ${#1} )); (( n > 0 )) && printf '%*s' "$n" ''; return 0; }

# --- the table --------------------------------------------------------------

if [[ "$MODE" == list ]]; then
    if [[ -t 1 ]]; then
        B=$'\e[1m'; D=$'\e[2m'; C=$'\e[36m'; N=$'\e[0m'
    else
        B=''; D=''; C=''; N=''
    fi

    last=""
    for row in "${ROWS[@]}"; do
        IFS=$'\t' read -r g k d <<< "$row"
        if [[ "$g" != "$last" ]]; then
            printf '\n%s%s%s\n' "$B" "$g" "$N"
            last="$g"
        fi
        printf '  %s%s%s%s  %s%s%s\n' "$C" "$k" "$N" "$(pad "$k")" "$D" "$d" "$N"
    done
    printf '\n  %sfrom %s%s\n\n' "$D" "$CONFIG" "$N"
    exit 0
fi

# --- or the searchable list -------------------------------------------------

command -v rofi >/dev/null || {
    printf 'shortcuts: rofi is not installed - printing instead\n' >&2
    exec "$0" --list ${FILTER:+"$FILTER"}
}

render_rofi_rows() {
    local last="" g k d row
    for row in "${ROWS[@]}"; do
        IFS=$'\t' read -r g k d <<< "$row"
        if [[ "$g" != "$last" ]]; then
            # A heading row. It is selectable, which costs nothing: selecting
            # anything here does nothing at all.
            printf '──  %s\n' "$g"
            last="$g"
        fi
        printf '%s%s  %s\n' "$k" "$(pad "$k")" "$d"
    done
}

# The theme is the one rofi already uses - generated from the wallpaper like
# everything else - with four things changed for this list: a monospace font,
# so the key column is a column; more lines, because a cheatsheet you have to
# scroll is a cheatsheet you close; a little more width for the longer
# descriptions; and the message row switched on, since theme.rasi builds
# mainbox out of an explicit list of children and -mesg would otherwise be
# accepted and then never drawn.
render_rofi_rows | rofi -dmenu -i -no-custom -p "keys" \
    -mesg "from ${CONFIG/#$HOME/\~} · type to filter · Escape to close" \
    -theme-str '* { font: "Fantasque Sans Mono 11"; }
                window { width: 52%; }
                mainbox { children: [ inputbar, message, listview ]; }
                listview { lines: 18; }' \
    >/dev/null 2>&1

exit 0
