#!/usr/bin/env bash
#
# fetch_wallpaper.sh - download a wallpaper and set it under X11.
#
# Two sources, one pipeline:
#
#   fetch_wallpaper.sh                  random landscape waifu from waifu.im
#   fetch_wallpaper.sh maid             extra tags (AND logic), waifu.im only
#   fetch_wallpaper.sh --bing           today's Bing image of the day
#
#   --per-monitor                       a different image on each monitor
#                                       (--bing walks back through recent days)
#   --monitor HDMI-1                    just that one, others left alone
#   --offline                           skip the network, use what is cached
#   --no-theme                          set the wallpaper, do not re-theme
#   DEBUG=1                             show the API call and what came back
#
# Each source keeps its own library under ~/.wallpaper/<source>, and both go
# through the same store-cap-apply-retheme path. Every image fetched is kept,
# so with no network the script picks one that is already there rather than
# failing. Each library is capped by total size and the oldest files are
# deleted to stay under it - a new image is always stored, something else
# makes room for it.

set -uo pipefail

# --- settings ---------------------------------------------------------------

SOURCE=waifu                            # or bing, via --bing

# Hard cap on a library, in megabytes.
MAX_MB="${WAIFU_MAX_MB:-50}"

ORIENTATION="LANDSCAPE"
STATE="$HOME/.cache/theme/wallpapers"   # which image is on which output

PER_MONITOR=0
OFFLINE=0
NO_THEME=0
TAGS=()

# --- output -----------------------------------------------------------------

if [[ -t 2 ]]; then D=$'\e[2m'; R=$'\e[31m'; N=$'\e[0m'; else D=''; R=''; N=''; fi
say()   { printf '%s\n' "$*" >&2; }
dbg()   { [[ -n "${DEBUG:-}" ]] && printf '%s  %s%s\n' "$D" "$*" "$N" >&2; return 0; }
die()   { printf '%sfetch_wallpaper: %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

# --- args -------------------------------------------------------------------

while (( $# )); do
    case "$1" in
        --bing)        SOURCE=bing ;;
        --waifu)       SOURCE=waifu ;;
        --per-monitor) PER_MONITOR=1 ;;
        --monitor)     shift; MONITOR="${1:-}" ;;
        --offline)     OFFLINE=1 ;;
        --no-theme)    NO_THEME=1 ;;
        --help|-h)
            # Everything from line 3 down to the first non-comment line, so the
            # help text cannot drift out of sync with a hardcoded line range.
            awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"
            exit 0 ;;
        -*)            die "unknown option: $1 (try --help)" ;;
        *)             TAGS+=("$1") ;;
    esac
    shift
done

# Lives under ~/.wallpaper alongside my_collection, not in ~/.cache: these are
# wallpapers you keep, and theme_init.sh looks for them here. One directory per
# source, so pruning one library never eats the other.
if [[ "$SOURCE" == bing ]]; then
    DIR="${BING_DIR:-$HOME/.wallpaper/bing}"
    (( ${#TAGS[@]} )) && say "fetch_wallpaper: bing has no tags, ignoring: ${TAGS[*]}"
else
    DIR="${WAIFU_DIR:-$HOME/.wallpaper/waifu}"
fi

for bin in curl feh xrandr; do
    command -v "$bin" >/dev/null || die "missing: $bin"
done
# jq is only needed to talk to the API; the offline path does not use it.
HAVE_JQ=0; command -v jq >/dev/null && HAVE_JQ=1

mkdir -p "$DIR" "$(dirname "$STATE")"

# --- the library ------------------------------------------------------------

list_images() {
    find -L "$DIR" -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
        2>/dev/null
}

dir_bytes() {
    local total=0 sz
    while read -r sz; do total=$(( total + sz )); done < <(
        list_images | xargs -r stat -c '%s' 2>/dev/null
    )
    printf '%s' "$total"
}

# Delete oldest-first until the directory fits under the cap. Anything passed
# as an argument is protected, so the image we just downloaded and applied is
# never the one thrown away to make room for itself.
prune() {
    local -a keep=("$@")
    local limit=$(( MAX_MB * 1024 * 1024 ))
    local used file protected removed=0 freed=0 sz

    used=$(dir_bytes)
    (( used <= limit )) && { dbg "library $(( used / 1024 / 1024 ))MB / ${MAX_MB}MB"; return 0; }

    # Oldest first by mtime.
    while IFS= read -r file; do
        (( used <= limit )) && break
        protected=0
        for k in "${keep[@]:-}"; do [[ "$file" == "$k" ]] && { protected=1; break; }; done
        (( protected )) && continue
        sz=$(stat -c '%s' "$file" 2>/dev/null || echo 0)
        rm -f -- "$file" && { used=$(( used - sz )); freed=$(( freed + sz )); removed=$(( removed + 1 )); }
    done < <(list_images | xargs -r stat -c '%Y %n' 2>/dev/null | sort -n | cut -d' ' -f2-)

    (( removed )) && say "  pruned $removed old wallpaper(s), freed $(( freed / 1024 / 1024 ))MB"
    return 0
}

# --- fetch ------------------------------------------------------------------

# Both sources echo the path of a newly downloaded image, or nothing on any
# failure, so the caller never has to know which one it asked.
# $1 is which image of a series this is, counting from 0. Only bing uses it -
# it cannot be a counter inside these functions, because every caller runs them
# in a "$(...)" subshell and any variable they increment dies with it.
fetch_one() {
    case "$SOURCE" in
        bing) fetch_bing "${1:-0}" ;;
        *)    fetch_waifu ;;
    esac
}

# Bing publishes one image a day, addressed by how many days back you want it.
# --per-monitor therefore walks backwards through the archive rather than
# asking for the same picture once per screen. Bing keeps about a week.
fetch_bing() {
    (( HAVE_JQ )) || { dbg "jq not installed - cannot query the API"; return 1; }

    local idx="$1"
    if (( idx > 7 )); then
        dbg "bing keeps about 8 days - nothing further back to ask for"
        return 1
    fi

    local api="https://www.bing.com/HPImageArchive.aspx?format=js&idx=${idx}&n=1&mkt=en-US"
    dbg "GET $api"

    local body base
    # --max-time so a captive portal or dead link cannot hang i3 startup.
    body=$(curl -sS --max-time 20 -H 'Accept: application/json' "$api" 2>/dev/null) || {
        dbg "curl failed"; return 1; }

    base=$(jq -r '.images[0].urlbase // empty' <<<"$body" 2>/dev/null)
    [[ -z "$base" ]] && { dbg "unexpected response: $body"; return 1; }

    # urlbase looks like "/th?id=OHR.VirginiaTrail_EN-US9403114082". The id is
    # stable per image, which is what makes it a good filename - re-running on
    # the same day finds the file already there instead of downloading twice.
    # The suffix picks a resolution; UHD is the largest Bing serves.
    local id="${base##*id=}"
    local file="$DIR/${id}_UHD.jpg"

    if [[ ! -f "$file" ]]; then
        curl -fsSL --max-time 60 -o "$file.part" "https://www.bing.com${base}_UHD.jpg" 2>/dev/null || {
            rm -f "$file.part"; dbg "download failed"; return 1; }
        mv -f "$file.part" "$file"
    fi
    touch "$file"                      # newest, so pruning keeps it longest
    dbg "got $(basename "$file") (bing idx $idx)"
    printf '%s' "$file"
}

fetch_waifu() {
    (( HAVE_JQ )) || { dbg "jq not installed - cannot query the API"; return 1; }

    local q="IsNsfw=False&Orientation=${ORIENTATION}&Width=%3E%3D${MIN_WIDTH}&OrderBy=Random&PageSize=1"
    local t
    for t in waifu "${TAGS[@]:-}"; do
        [[ -n "$t" ]] && q+="&IncludedTags=${t}"
    done

    local api="https://api.waifu.im/images?${q}"
    dbg "GET $api"

    local resp code body
    # --max-time so a captive portal or dead link cannot hang i3 startup.
    resp=$(curl -sS --max-time 20 -w '\n%{http_code}' -H 'Accept: application/json' "$api" 2>/dev/null) || {
        dbg "curl failed"; return 1; }
    code=${resp##*$'\n'}
    body=${resp%$'\n'*}

    [[ "$code" == "200" ]] || { dbg "api HTTP $code: $body"; return 1; }

    local url w h bytes
    read -r url w h bytes < <(
        jq -r '.items[0] | "\(.url) \(.width) \(.height) \(.byteSize)"' <<<"$body" 2>/dev/null
    )
    [[ -z "$url" || "$url" == "null" ]] && { dbg "no match"; return 1; }

    # A single image larger than the whole budget can never be stored.
    if [[ "$bytes" =~ ^[0-9]+$ ]] && (( bytes > MAX_MB * 1024 * 1024 )); then
        dbg "image is ${bytes} bytes, larger than the ${MAX_MB}MB cap - skipping"
        return 1
    fi

    local file="$DIR/$(basename "$url")"
    if [[ ! -f "$file" ]]; then
        curl -fsSL --max-time 60 -o "$file.part" "$url" 2>/dev/null || {
            rm -f "$file.part"; dbg "download failed"; return 1; }
        mv -f "$file.part" "$file"
    fi
    touch "$file"                      # newest, so pruning keeps it longest
    dbg "got $(basename "$file") ${w}x${h}"
    printf '%s' "$file"
}

pick_cached() {
    list_images | shuf -n 1
}

# --- monitors ---------------------------------------------------------------

# feh assigns images to monitors in Xinerama order, which is what
# `xrandr --listmonitors` reports, so read the order from there.
mapfile -t OUTPUTS < <(xrandr --listmonitors 2>/dev/null | awk 'NR > 1 { print $NF }')
(( ${#OUTPUTS[@]} == 0 )) && mapfile -t OUTPUTS < <(xrandr --query | awk '/ connected/ {print $1}')
(( ${#OUTPUTS[@]} == 0 )) && die "no connected outputs"

# Ask for images at least as wide as the widest monitor, so nothing is upscaled.
MIN_WIDTH=$(xrandr --query | grep -oP '^\S+ connected.*?\K[0-9]+(?=x[0-9]+\+)' | sort -rn | head -1)
[[ -z "$MIN_WIDTH" ]] && MIN_WIDTH=1920
dbg "outputs: ${OUTPUTS[*]}  min width: $MIN_WIDTH"

declare -A CURRENT=()
if [[ -f "$STATE" ]]; then
    while IFS=$'\t' read -r out path; do
        [[ -n "$out" && -f "$path" ]] && CURRENT["$out"]="$path"
    done < "$STATE"
fi

# --- choose ------------------------------------------------------------------

get_image() {
    local f=""
    (( OFFLINE )) || f="$(fetch_one "${1:-0}")"
    if [[ -z "$f" ]]; then
        f="$(pick_cached)"
        [[ -n "$f" ]] && dbg "offline - using cached $(basename "$f")"
    fi
    printf '%s' "$f"
}

TARGETS=()
if [[ -n "${MONITOR:-}" ]]; then
    TARGETS=("$MONITOR")
elif (( PER_MONITOR )); then
    TARGETS=("${OUTPUTS[@]}")
else
    TARGETS=("${OUTPUTS[@]}")          # same image everywhere
fi

NEW=()
if (( PER_MONITOR )) || [[ -n "${MONITOR:-}" ]]; then
    n=0
    for m in "${TARGETS[@]}"; do
        img="$(get_image "$n")"
        n=$(( n + 1 ))
        [[ -z "$img" ]] && die "no wallpaper available (no network and nothing cached in $DIR)"
        CURRENT["$m"]="$img"
        NEW+=("$img")
    done
else
    img="$(get_image)"
    [[ -z "$img" ]] && die "no wallpaper available (no network and nothing cached in $DIR)"
    for m in "${OUTPUTS[@]}"; do CURRENT["$m"]="$img"; done
    NEW+=("$img")
fi

# --- apply -------------------------------------------------------------------

FILES=()
for m in "${OUTPUTS[@]}"; do
    # A monitor with no entry yet (just plugged in) gets the newest image.
    FILES+=("${CURRENT[$m]:-${NEW[0]}}")
done

feh --bg-fill "${FILES[@]}" || die "feh failed to set the wallpaper"

: > "$STATE"
for m in "${OUTPUTS[@]}"; do
    printf '%s\t%s\n' "$m" "${CURRENT[$m]}" >> "$STATE"
done

# --- trim --------------------------------------------------------------------
# After storing, not before: the new image is kept and something older goes.
prune "${FILES[@]}"

# --- re-theme ----------------------------------------------------------------
# The palette comes from the image on the first monitor, which is the primary.
if (( ! NO_THEME )) && [[ -x "$HOME/.config/i3/script/theme_init.sh" ]]; then
    "$HOME/.config/i3/script/theme_init.sh" --file "${FILES[0]}" --no-wallpaper
fi

for i in "${!OUTPUTS[@]}"; do
    say "set: ${OUTPUTS[$i]} -> $(basename "${FILES[$i]}")"
done
say "library: $(( $(dir_bytes) / 1024 / 1024 ))MB / ${MAX_MB}MB in $DIR"
