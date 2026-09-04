#!/usr/bin/env bash
#
# netspeed.sh - one live up/down readout, for the link actually carrying traffic.
#
#   netspeed.sh watch     the bar's meter; never exits
#   netspeed.sh once      one reading, and exit
#   netspeed.sh iface     which interface it is following, and why
#
#
# Why this replaced two internal/network modules
# ----------------------------------------------
#
# The bar used to carry [module/wired-network] and [module/wireless-network]
# side by side, on the reasoning that a laptop is on a dongle or on wifi but
# never both, so exactly one of them would ever be visible.
#
# That is not true, and this machine is the counter-example: a phone tethered
# over USB and wifi still associated. Both interfaces are up, both modules
# render, and the bar shows two speed meters - one of them reading essentially
# zero, because only one of the two links is carrying anything.
#
#   default via 10.138.253.74 dev enp0s20f0u1  metric 100   <- the traffic
#   default via 192.168.1.1   dev wlp2s0       metric 600   <- up, unused
#
# It is not fixable by configuration. internal/network selects by interface
# *type*, and neither module can know the other exists, let alone which of the
# two owns the route. And "which link am I actually using" is the question a
# speed meter is being asked in the first place - answering it per interface
# type was always answering something else.
#
# So: one module, following the default route. Two interfaces up is then not a
# special case, it is just a routing table with two entries and a winner.
#
#
# How the interface is chosen
# ---------------------------
#
# `ip route get` first, because it is the kernel's own answer. It accounts for
# metrics, policy rules, VPN tables and anything else that decides where a
# packet really goes - all things a metric comparison here would have to
# reimplement and would eventually get wrong.
#
# The fallback, for a machine with no route to the probe address, is the first
# default route, which the kernel lists in metric order.
#
# Nothing is hardcoded: no interface name, no type, no assumption about how
# many links are up. Unplug the tether and this follows wifi on the next tick,
# with no restart and no re-detection step.

set -uo pipefail

INTERVAL="${NETSPEED_INTERVAL:-1}"

# Font Awesome download/upload, U+F019 and U+F093 - the same two the network
# modules used, and in the range that has survived every Nerd Font version.
DOWN="${NETSPEED_DOWN_GLYPH:-}"
UP="${NETSPEED_UP_GLYPH:-}"

# Each rate is padded to this width so the bar does not jitter sideways every
# time a reading gains or loses a digit. The old modules did it with polybar's
# %downspeed:9% token; this does it here, for the same reason.
WIDTH="${NETSPEED_WIDTH:-9}"

default_iface() {
    local dev
    dev="$(ip route get 1.1.1.1 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
    if [[ -n "$dev" ]]; then
        printf '%s\n' "$dev"
        return 0
    fi
    ip route show default 2>/dev/null |
        awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

# Bytes per second as something readable, in pure bash - no awk, no bc. This
# runs twice a second forever, so it is worth not spawning anything.
human() {
    local b="$1"
    if (( b >= 1048576 )); then
        printf '%d.%d MB/s' $(( b / 1048576 )) $(( b % 1048576 * 10 / 1048576 ))
    elif (( b >= 1024 )); then
        printf '%d KB/s' $(( b / 1024 ))
    else
        printf '%d B/s' "$b"
    fi
}

emit() {
    printf '%s %*s  %s %*s\n' \
        "$DOWN" "$WIDTH" "$(human "$1")" \
        "$UP"   "$WIDTH" "$(human "$2")"
}

counters() {
    local iface="$1" rx tx
    read -r rx < "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || return 1
    read -r tx < "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || return 1
    printf '%s %s\n' "$rx" "$tx"
}

watch_speed() {
    local iface prev="" rx0=0 tx0=0 rx1 tx1 drx dtx

    while :; do
        iface="$(default_iface)"

        # No default route: nothing is connected, so the module shows nothing
        # at all rather than a meter reading zero. An empty line is how a
        # tail'd custom/script says "render me as absent" - the same thing
        # `format-disconnected =` did for the modules this replaced.
        if [[ -z "$iface" ]]; then
            printf '\n'
            prev=""
            sleep "$INTERVAL"
            continue
        fi

        if ! read -r rx1 tx1 < <(counters "$iface"); then
            printf '\n'
            prev=""
            sleep "$INTERVAL"
            continue
        fi

        if [[ "$iface" == "$prev" ]]; then
            drx=$(( (rx1 - rx0) / INTERVAL ))
            dtx=$(( (tx1 - tx0) / INTERVAL ))
            # A counter that went backwards is an interface that was reset, not
            # negative traffic.
            (( drx < 0 )) && drx=0
            (( dtx < 0 )) && dtx=0
            emit "$drx" "$dtx"
        else
            # First sample on a new interface - the tether was just unplugged,
            # or this is the first tick. There is no previous reading to
            # subtract that would mean anything, so show idle for one tick
            # rather than the interface's lifetime total as a one-second rate.
            emit 0 0
        fi

        rx0="$rx1" tx0="$tx1" prev="$iface"
        sleep "$INTERVAL"
    done
}

case "${1:-watch}" in
    watch)
        watch_speed
        ;;
    once)
        iface="$(default_iface)"
        [[ -n "$iface" ]] || { printf '\n'; exit 0; }
        read -r rx0 tx0 < <(counters "$iface") || { printf '\n'; exit 0; }
        sleep "$INTERVAL"
        read -r rx1 tx1 < <(counters "$iface") || { printf '\n'; exit 0; }
        emit $(( (rx1 - rx0) / INTERVAL )) $(( (tx1 - tx0) / INTERVAL ))
        ;;
    iface)
        iface="$(default_iface)"
        if [[ -z "$iface" ]]; then
            printf 'netspeed: no default route - nothing is connected\n' >&2
            exit 1
        fi
        printf '%s\n' "$iface"
        printf '  chosen by: %s\n' \
            "$(ip route get 1.1.1.1 >/dev/null 2>&1 && echo "ip route get (the kernel's own choice)" || echo 'first default route (no route to the probe address)')"
        ip route show default | sed 's/^/  /'
        ;;
    --help|-h)
        awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
        ;;
    *)
        printf 'netspeed: unknown action: %s (try --help)\n' "${1:-}" >&2
        exit 2
        ;;
esac
