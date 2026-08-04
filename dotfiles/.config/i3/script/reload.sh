#!/usr/bin/env bash
#
# reload.sh - reload or restart i3, and say which way it went.
#
#   reload.sh reload        re-read the config into the running i3
#   reload.sh restart       re-exec i3, keeping the layout and the session
#   reload.sh check         say whether the config is valid, change nothing
#
# reload and restart are bound to $mod+Shift+c and $mod+Shift+r, and report
# through a notification because a keybinding has no terminal to print to.
# check is for a terminal, and prints i3's own output.
#
# Why a script and not two lines in the config:
#
# i3 does not hand an exec line to the shell untouched. It runs its own command
# parser over it first, and in that parser `;` and `,` separate i3 commands.
# They are only literal inside a *double-quoted* argument - single quotes mean
# nothing to it. So a binding written the obvious way:
#
#   bindsym $mod+Shift+c exec sh -c 'if i3-msg -q reload; then ...; fi'
#
# is read as two commands: `exec sh -c 'if i3-msg -q reload'`, which it runs,
# and `then ...; fi`, which it cannot parse. The half that reloads works, the
# half that reports does not, and i3 answers a keypress with
#
#   ERROR: Expected one of these tokens: <end>, '[', 'move', 'exec', ...
#
# Double-quoting the whole argument fixes the parse and leaves three levels of
# nested quoting around every string the notification wants to say. The shell
# logic lives here instead, and the config line stays a path and a word.
#
# Why the config is checked before either action, rather than after:
#
#   - A reload that failed and a reload that worked look identical from the
#     keyboard - the desktop does not change either way. `i3-msg -q reload`
#     exits non-zero when i3 refuses the config, which is what makes the two
#     tellable apart, but by then i3 has already put a nagbar on screen.
#   - `restart` does not fail on a broken config at all. i3 re-execs, the new
#     process reads the file, complains, and carries on with the parts it
#     understood. There is nothing left for a keybinding to check. Checking
#     first is the only way `$mod+Shift+r` can decline to restart into a
#     config it can already see is broken.
#   - `i3 -C` prints the offending line and the reason. That fits in a
#     notification, which "see the error at the top of the screen" does not.
#
# `i3 -C` reads the config the same way i3 does, but it stops at directives:
# the *commands* attached to bindsym are parsed lazily, at press time, so a
# binding that i3 will reject is not something this - or any other check short
# of pressing the key - can catch. That is the bug described above, and why it
# survived in a config that `i3 -C` called clean.

set -uo pipefail

NOTIFY="$HOME/.config/i3/script/notify.sh"
CONFIG="${I3_CONFIG:-$HOME/.config/i3/config}"

ACTION="${1:-reload}"

say_ok()  { "$NOTIFY" -u low -T 2000 -t i3 -i view-refresh "i3" "$1"; }
say_bad() { "$NOTIFY" -u critical -t i3 -i dialog-error "i3" "$1"; }

# The first thing i3 -C objected to, as one line of prose. Exits 0 and prints
# the complaint when there is one, 1 when the config is clean - so the callers
# below read as `if there is a config error, refuse`.
#
# Its output is several lines per error - the token list, the file, the lines
# around the problem, a caret. The line number and the message are the two
# parts worth reading from a popup; the rest is only useful next to the file.
config_error() {
    local out culprit
    [[ -r "$CONFIG" ]] || { printf 'no config to read at %s' "$CONFIG"; return 0; }
    out="$(i3 -C -c "$CONFIG" 2>&1)" && return 1

    # i3 prints the line it choked on with a row of carets under it, inside a
    # few lines of context. The line under the carets is the answer; the
    # "Expected one of these tokens" list above it is fifty directive names
    # that no popup can hold and nobody reads anyway.
    culprit="$(printf '%s\n' "$out" |
        sed -n 's/.*ERROR: CONFIG: //p' |
        awk '
            /^ *\^+ *$/ && last != "" { print last; found = 1; exit }
            /^Line +[0-9]+:/          { last = $0 }
            END { if (!found && last != "") print last }
        ' |
        sed 's/^Line  *\([0-9]*\): */line \1: /' |
        cut -c1-110)"

    printf '%s' "${culprit:-i3 rejected the config}"
    return 0
}

case "$ACTION" in
    reload)
        if err="$(config_error)"; then
            say_bad "config refused - $err"
            exit 1
        fi
        # Checked and still refused: i3 saw something `i3 -C` did not (a
        # workspace assignment it cannot honour, a font it cannot open). Say
        # so rather than claiming success, and leave i3's nagbar to explain.
        if i3-msg -q reload; then
            say_ok "config reloaded"
        else
            say_bad "reload refused - see the error at the top of the screen"
            exit 1
        fi
        ;;
    restart)
        if err="$(config_error)"; then
            say_bad "restart refused - $err"
            exit 1
        fi
        # The notification outlives the restart: i3 re-execs itself, dunst is
        # a separate process and does not. i3 hands this client's reply across
        # the restart, so a zero exit here means the new i3 came up.
        if i3-msg -q restart; then
            say_ok "restarted"
        else
            say_bad "restart failed - i3 did not come back up"
            exit 1
        fi
        ;;
    check)
        # No notification: this one is for a terminal, where the full output
        # is more use than a summary of it.
        i3 -C -c "$CONFIG" && printf 'i3: %s is valid\n' "$CONFIG"
        ;;
    --help|-h)
        awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
        ;;
    *)
        printf 'reload: unknown action: %s (try --help)\n' "$ACTION" >&2
        exit 2
        ;;
esac
