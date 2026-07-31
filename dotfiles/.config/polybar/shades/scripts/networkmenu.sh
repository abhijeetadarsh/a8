#!/usr/bin/env bash
#
# networkmenu.sh - connect to wifi or ethernet from the bar, without nmtui.
#
#   networkmenu.sh            open the menu (polybar's network module clicks this)
#   networkmenu.sh --status   one line for the bar itself
#
# Everything goes through nmcli, so this is the same NetworkManager state that
# nmtui and nm-applet see - connections made here are saved and come back on
# their own after a reboot.
#
# The rofi theme is scripts/rofi/networkmenu.rasi, which imports the generated
# colours, so the menu follows the wallpaper like everything else.

set -uo pipefail

DIR="$HOME/.config/polybar/shades"
RASI="$DIR/scripts/rofi/networkmenu.rasi"

notify() { command -v notify-send >/dev/null && notify-send -a network "$@"; }

# nmcli --terse escapes ':' and '\' inside values so the field separator stays
# unambiguous. Anything printed to the user has to be unescaped again, or an
# SSID with a colon in it shows up with backslashes.
unescape() { printf '%s' "${1//\\:/:}" | sed 's/\\\\/\\/g'; }

# --- the bar label ----------------------------------------------------------

if [[ "${1:-}" == "--status" ]]; then
    # Whatever is actually carrying traffic, wifi or wired - not a fixed
    # interface name. A config that names wlp2s0 works on exactly one machine.
    while IFS=: read -r dev type state conn; do
        [[ "$state" == connected ]] || continue
        case "$type" in
            wifi)
                sig=$(nmcli -t -f IN-USE,SIGNAL dev wifi list ifname "$dev" 2>/dev/null |
                      awk -F: '$1 == "*" { print $2; exit }')
                printf '%s %s%%\n' "$(unescape "$conn")" "${sig:-?}"
                exit 0 ;;
            ethernet)
                printf '%s\n' "$(unescape "$conn")"
                exit 0 ;;
        esac
    done < <(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null)

    if [[ "$(nmcli -t radio wifi 2>/dev/null)" == disabled ]]; then
        printf 'wifi off\n'
    else
        printf 'offline\n'
    fi
    exit 0
fi

# --- the menu ---------------------------------------------------------------

command -v rofi  >/dev/null || { notify "rofi is not installed"; exit 1; }
command -v nmcli >/dev/null || { notify "NetworkManager is not installed"; exit 1; }

menu() {
    rofi -dmenu -i -no-custom -p "${2:-network}" -theme "$RASI" <<<"$1"
}

WIFI_STATE="$(nmcli -t radio wifi 2>/dev/null)"

# A rescan makes the list current, but nmcli errors if one is already running
# and the cached list is fine in that case - so the failure is deliberately
# ignored rather than reported.
[[ "$WIFI_STATE" == enabled ]] && nmcli dev wifi rescan >/dev/null 2>&1

ENTRIES=""
declare -A SSID_OF=()   # menu line -> what to connect to
declare -A SEEN=()      # SSID -> already listed

if [[ "$WIFI_STATE" == enabled ]]; then
    # IN-USE, SIGNAL and SECURITY never contain a colon; the SSID can, so it
    # goes last and takes the rest of the line.
    while IFS= read -r line; do
        inuse="${line%%:*}";  rest="${line#*:}"
        signal="${rest%%:*}"; rest="${rest#*:}"
        sec="${rest%%:*}";    ssid="${rest#*:}"
        ssid="$(unescape "$ssid")"
        [[ -z "$ssid" ]] && continue              # hidden network
        # One SSID can appear several times: two bands, or a mesh with more
        # than one access point. nmcli lists them strongest first, so the first
        # one seen is the one worth offering.
        [[ -n "${SEEN[$ssid]:-}" ]] && continue
        SEEN["$ssid"]=1

        mark=" "; [[ "$inuse" == "*" ]] && mark="*"
        # Open networks are the ones worth flagging. Tagging the secured ones
        # instead puts a marker on almost every line, which says nothing.
        open=""; [[ "$sec" == "--" || -z "$sec" ]] && open="  (open)"
        label="$(printf '%s %3s%%  %s%s' "$mark" "$signal" "$ssid" "$open")"
        SSID_OF["$label"]="$ssid"
        ENTRIES+="$label"$'\n'
    done < <(nmcli -t -f IN-USE,SIGNAL,SECURITY,SSID dev wifi list 2>/dev/null)
fi

# Saved wired profiles, so a dock or a cable is one click too.
while IFS=: read -r name type; do
    [[ "$type" == "802-3-ethernet" ]] || continue
    label="  wired: $(unescape "$name")"
    SSID_OF["$label"]="wired:$(unescape "$name")"
    ENTRIES+="$label"$'\n'
done < <(nmcli -t -f NAME,TYPE connection show 2>/dev/null)

if [[ "$WIFI_STATE" == enabled ]]; then
    ENTRIES+="  turn wifi off"$'\n'
else
    ENTRIES+="  turn wifi on"$'\n'
fi
ENTRIES+="  disconnect"$'\n'

CHOICE="$(menu "$ENTRIES")"
[[ -z "$CHOICE" ]] && exit 0

case "$CHOICE" in
    "  turn wifi off")
        nmcli radio wifi off && notify "Wi-Fi" "turned off"
        exit 0 ;;
    "  turn wifi on")
        nmcli radio wifi on && notify "Wi-Fi" "turned on"
        exit 0 ;;
    "  disconnect")
        # The device, not the profile: `connection down` on a profile that is
        # not up does nothing and says so, which reads as the click failing.
        while IFS=: read -r dev type state _; do
            [[ "$state" == connected ]] || continue
            [[ "$type" == wifi || "$type" == ethernet ]] || continue
            nmcli device disconnect "$dev" >/dev/null 2>&1
        done < <(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null)
        notify "Network" "disconnected"
        exit 0 ;;
esac

TARGET="${SSID_OF[$CHOICE]:-}"
[[ -z "$TARGET" ]] && exit 0

if [[ "$TARGET" == wired:* ]]; then
    name="${TARGET#wired:}"
    if nmcli connection up "$name" >/dev/null 2>&1; then
        notify "Network" "connected to $name"
    else
        notify -u critical "Network" "could not bring up $name"
    fi
    exit 0
fi

# Already on it - selecting it again should be a no-op, not a reconnect that
# drops the link for a second.
if [[ "$CHOICE" == "*"* ]]; then
    notify "Wi-Fi" "already connected to $TARGET"
    exit 0
fi

# A saved profile has the key already; only ask when there is nothing stored.
if nmcli -t -f NAME connection show 2>/dev/null | grep -qxF "$TARGET"; then
    if nmcli connection up id "$TARGET" >/dev/null 2>&1; then
        notify "Wi-Fi" "connected to $TARGET"
        exit 0
    fi
    # A stored key that no longer works falls through to the prompt below.
fi

if [[ "$CHOICE" == *"(open)" ]]; then
    out="$(nmcli device wifi connect "$TARGET" 2>&1)"
else
    PASS="$(rofi -dmenu -password -p "password for $TARGET" \
            -theme "$RASI" </dev/null)"
    [[ -z "$PASS" ]] && exit 0
    out="$(nmcli device wifi connect "$TARGET" password "$PASS" 2>&1)"
fi

if [[ "$out" == *successfully* ]]; then
    notify "Wi-Fi" "connected to $TARGET"
else
    # nmcli's own words are more use than "failed" - it distinguishes a wrong
    # password from a network that vanished between the scan and the click.
    notify -u critical "Wi-Fi" "${out:-could not connect to $TARGET}"
fi
