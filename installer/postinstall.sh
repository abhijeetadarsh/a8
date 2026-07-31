#!/usr/bin/env bash
#
# postinstall.sh - build the user layer on a freshly installed Arch system.
#
# archsetup.py installs the system layer (disks, kernel, drivers, bootloader,
# NetworkManager). This installs everything above it: the X server, the audio
# stack, the i3 desktop, the apps, and this repo's dotfiles.
#
# Run it as your normal user (NOT root) after the first boot:
#
#     git clone <this-repo> ~/arch-setup
#     ~/arch-setup/installer/postinstall.sh
#
# Re-running it is the supported way to fix a half-finished install: it checks
# what is actually on the system with pacman -Q, shows you what is missing, and
# lets you pick what to install or reinstall.
#
#   --repair    always show the package picker, even if nothing is missing
#   --yes       never ask anything (for automation)
#   --no-update skip the initial pacman -Syu
#   --help

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$HOME/.local/state/arch-setup"
LAST_RUN="$STATE_DIR/last-run"

ASSUME_YES=0
FORCE_REPAIR=0
DO_UPDATE=1

# ============================================================================
# output
#
# The shape here is deliberate: one line per thing that happened, indented
# under the step it belongs to, and no output at all for things that were
# already fine on a re-run. A second run of this script should be quiet.
# ============================================================================

if [[ -t 1 ]]; then
    B=$'\e[1m'; D=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'
    C=$'\e[36m'; N=$'\e[0m'
else
    B=''; D=''; G=''; Y=''; R=''; C=''; N=''
fi

say()   { printf '%s\n' "$*"; }
blank() { printf '\n'; }
step()  { printf '\n%s●%s %s\n' "$C" "$N" "$*"; }
note()  { printf '  %s⎿ %s%s\n' "$D" "$*" "$N"; }
ok()    { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn()  { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()   { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
die()   { printf '\n%s✗%s %s\n\n' "$R" "$N" "$*" >&2; exit 1; }

# Ask a yes/no question. Defaults to yes; --yes answers everything.
confirm() {
    local prompt="$1" reply
    (( ASSUME_YES )) && return 0
    printf '\n  %s %s[Y/n]%s ' "$prompt" "$D" "$N"
    read -r reply || return 1
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# ============================================================================
# packages
#
# One group per purpose. This is the only place to edit when adding software -
# the picker, the missing-package check and the install all read these arrays.
# ============================================================================

# --- the display server + session -------------------------------------------
PKGS_X=(
    xorg-server xorg-xinit
    xorg-xrandr xorg-xset xorg-xsetroot xorg-xrdb xorg-setxkbmap
    xorg-xprop            # used when finding window classes for i3 assigns
)

# --- audio ------------------------------------------------------------------
# The i3 volume keys call pactl, which needs a running pipewire-pulse.
PKGS_AUDIO=( pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol )

# --- networking -------------------------------------------------------------
# networkmanager itself is installed and enabled by archsetup.py; this is the
# tray applet the i3 config autostarts, plus wifi/bluetooth support.
PKGS_NET=( network-manager-applet bluez bluez-utils blueman )

# --- the i3 desktop ---------------------------------------------------------
PKGS_I3=(
    i3-wm i3status
    # NOT i3lock: the AUR's i3lock-color below is a drop-in replacement that
    # provides the same `i3lock` binary plus the --*-color flags that
    # .config/i3/script/i3lock-color.sh is built around. pacman treats them as
    # conflicting, so installing both just fails.
    xss-lock              # i3 config: lock on suspend
    dex                   # i3 config: exec dex --autostart
    picom                 # compositor
    polybar               # the bar
    rofi                  # launcher + powermenu
    feh                   # wallpaper setter
    dunst libnotify       # notify-send from polybar's updates.sh
    xdg-user-dirs
)

# --- screenshots / clipboard (bound to the Print keys) ----------------------
PKGS_SHOT=( maim xdotool xclip )

# --- terminals, shell, editor ----------------------------------------------
PKGS_TOOLS=(
    kitty                 # $mod+Return, and what ranger's image previews target
    starship eza          # .bashrc: prompt + `ls` alias
    neovim
    ranger                # $mod+n
    python-pillow         # ranger image previews
    highlight atool       # ranger's scope.sh: syntax + archive previews
    ripgrep fd fzf        # telescope / grep
    jq                    # fetch_wallpaper.sh parses the waifu.im API
    base-devel git curl wget
    unzip tree htop
    stow                  # how this repo's dotfiles get linked
    pacman-contrib        # checkupdates, for the polybar updates module
    psmisc procps-ng      # killall / pgrep, used by polybar's launch.sh
)

# --- apps the i3 workspace assigns expect ----------------------------------
PKGS_APPS=( firefox thunar exo )   # exo provides exo-open, used by polybar modules

# --- fonts + icons ----------------------------------------------------------
PKGS_FONTS=(
    ttf-fantasque-sans-mono       # the i3 bar/title font
    ttf-cascadia-code-nerd        # workspace glyphs in the i3 config
    noto-fonts noto-fonts-emoji
    papirus-icon-theme            # dunst + GTK icon theme
    adwaita-icon-theme            # cursor theme named in gtk settings.ini
)

# --- theming ----------------------------------------------------------------
# python-* drive theme_engine, which derives the whole desktop palette from the
# wallpaper. gnome-themes-extra is what actually provides the Adwaita-dark GTK3
# theme that gtk-3.0/settings.ini asks for - without it GTK apps stay light.
#
# No qt5ct/qt6ct here on purpose: .xinitrc falls back to Qt's gtk3 platform
# theme, which makes Qt apps read the generated GTK theme. That is two fewer
# packages for the same result. Install qt6ct if you want an exact Qt palette -
# the theme engine writes its config as soon as the binary exists.
PKGS_THEME=(
    python python-numpy python-scikit-learn python-opencv python-matplotlib
    gnome-themes-extra
)

# --- AUR --------------------------------------------------------------------
# Built with makepkg directly - see the AUR section below for why there is no
# helper. jump-bin rather than jump: it ships a prebuilt binary, so this needs
# no Go toolchain and installs in seconds. It provides the same `jump` command
# that .bashrc's `j` function calls.
#
# jump-bin     - the `j` command in .bashrc
# i3lock-color - used by .config/i3/script/i3lock-color.sh
AUR_PKGS=( jump-bin i3lock-color )

# Ordered groups for the picker: "label|pkg pkg pkg".
PKG_GROUPS=(
    "X server|${PKGS_X[*]}"
    "audio|${PKGS_AUDIO[*]}"
    "network|${PKGS_NET[*]}"
    "i3 desktop|${PKGS_I3[*]}"
    "screenshots|${PKGS_SHOT[*]}"
    "tools|${PKGS_TOOLS[*]}"
    "apps|${PKGS_APPS[*]}"
    "fonts|${PKGS_FONTS[*]}"
    "theming|${PKGS_THEME[*]}"
    "AUR|${AUR_PKGS[*]}"
)

# ============================================================================
# package helpers
# ============================================================================

# Cache of installed package names, refreshed after every install so the
# picker and the verification pass always reflect reality rather than what we
# think we asked for.
declare -A INSTALLED=()

refresh_installed() {
    INSTALLED=()
    local pkg
    while read -r pkg _; do
        INSTALLED["$pkg"]=1
    done < <(pacman -Q 2>/dev/null)
}

is_installed() { [[ -n "${INSTALLED[$1]:-}" ]]; }

# "Installed" is not just "a package with this exact name is in the database".
# base-devel is a group, and several entries here can be satisfied by a
# different package that provides them. Getting this wrong means the picker
# reports things as missing forever and reinstalls them on every run.
is_satisfied() {
    # Cheap exact-name hit first - true for the overwhelming majority.
    is_installed "$1" && return 0

    # A group counts as satisfied when every one of its members is installed.
    local members member
    members="$(pacman -Sgq "$1" 2>/dev/null)"
    if [[ -n "$members" ]]; then
        while read -r member; do
            [[ -z "$member" ]] && continue
            is_installed "$member" || return 1
        done <<< "$members"
        return 0
    fi

    # pacman -T resolves provides: exit 0 means something installed satisfies it.
    pacman -T "$1" >/dev/null 2>&1
}

is_aur() {
    local p
    for p in "${AUR_PKGS[@]}"; do [[ "$p" == "$1" ]] && return 0; done
    return 1
}

# ============================================================================
# the picker
#
# Builds one numbered list of every package this script manages, marked with
# what is actually on the system right now. Missing ones are preselected;
# anything else can be chosen to force a reinstall, and extra packages can be
# typed in with +name. This is what makes a re-run useful after a failure.
# ============================================================================

PICK_NAMES=()     # index -> package name
PICK_STATE=()     # index -> "missing" | "installed"

build_pick_list() {
    PICK_NAMES=(); PICK_STATE=()
    local entry label pkgs pkg
    for entry in "${PKG_GROUPS[@]}"; do
        label="${entry%%|*}"; pkgs="${entry#*|}"
        for pkg in $pkgs; do
            PICK_NAMES+=("$pkg")
            if is_satisfied "$pkg"; then
                PICK_STATE+=("installed")
            else
                PICK_STATE+=("missing")
            fi
        done
    done
}

print_pick_list() {
    local entry label pkgs pkg i=0 shown
    for entry in "${PKG_GROUPS[@]}"; do
        label="${entry%%|*}"; pkgs="${entry#*|}"
        printf '\n  %s%s%s\n' "$B" "$label" "$N"
        for pkg in $pkgs; do
            i=$((i + 1))
            if [[ "${PICK_STATE[$((i - 1))]}" == "missing" ]]; then
                shown=$(printf '%s%3d%s  %-28s %smissing%s' \
                        "$Y" "$i" "$N" "$pkg" "$Y" "$N")
            else
                shown=$(printf '%s%3d%s  %s%-28s installed%s' \
                        "$D" "$i" "$N" "$D" "$pkg" "$N")
            fi
            printf '    %s\n' "$shown"
        done
    done
}

# Turn what the user typed into a list of package names on stdout.
# Understands: all, missing, none, 12, 3-9, 3,4, +extra-package
parse_selection() {
    local input="$1" token n a b i
    local -a out=()

    # Commas are just separators.
    input="${input//,/ }"

    for token in $input; do
        case "$token" in
            all)
                out+=("${PICK_NAMES[@]}")
                ;;
            missing|m)
                for i in "${!PICK_NAMES[@]}"; do
                    [[ "${PICK_STATE[$i]}" == "missing" ]] && out+=("${PICK_NAMES[$i]}")
                done
                ;;
            none|n|q)
                return 0
                ;;
            +*)
                # An arbitrary package that is not in this script's lists.
                out+=("${token#+}")
                ;;
            *-*)
                a="${token%%-*}"; b="${token##*-}"
                if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]]; then
                    for (( n = a; n <= b; n++ )); do
                        (( n >= 1 && n <= ${#PICK_NAMES[@]} )) && out+=("${PICK_NAMES[$((n - 1))]}")
                    done
                else
                    # Not a range - a package name with a dash in it.
                    out+=("$token")
                fi
                ;;
            [0-9]*)
                n="$token"
                if (( n >= 1 && n <= ${#PICK_NAMES[@]} )); then
                    out+=("${PICK_NAMES[$((n - 1))]}")
                else
                    warn "ignoring out-of-range selection: $n" >&2
                fi
                ;;
            *)
                out+=("$token")
                ;;
        esac
    done

    # De-duplicate, keep order.
    local -A seen=()
    for token in "${out[@]:-}"; do
        [[ -z "$token" ]] && continue
        [[ -n "${seen[$token]:-}" ]] && continue
        seen["$token"]=1
        printf '%s\n' "$token"
    done
}

# Show the picker and echo the chosen package names, one per line.
run_picker() {
    local missing_count=0 i reply
    for i in "${!PICK_STATE[@]}"; do
        [[ "${PICK_STATE[$i]}" == "missing" ]] && missing_count=$((missing_count + 1))
    done

    print_pick_list >&2

    {
        blank
        if (( missing_count )); then
            printf '  %s%d of %d packages are missing.%s\n' \
                "$B" "$missing_count" "${#PICK_NAMES[@]}" "$N"
        else
            printf '  %sEverything on the list is installed.%s\n' "$B" "$N"
        fi
        blank
        printf '  %sWhat should I install?%s\n' "$B" "$N"
        blank
        printf '    %smissing%s  just the missing ones%s\n' "$G" "$D" "$N"
        printf '    %s1 5 12%s   those numbers - already-installed ones get reinstalled%s\n' "$G" "$D" "$N"
        printf '    %s4-9%s      ranges work, and so do commas%s\n' "$G" "$D" "$N"
        printf '    %s+name%s    a package that is not on this list at all%s\n' "$G" "$D" "$N"
        printf '    %sall%s      reinstall everything%s\n' "$G" "$D" "$N"
        printf '    %snone%s     skip this step%s\n' "$G" "$D" "$N"
        blank
    } >&2

    if (( ASSUME_YES )); then
        reply="missing"
    else
        printf '  %s>%s ' "$C" "$N" >&2
        read -r reply || reply="none"
    fi
    [[ -z "$reply" ]] && reply="missing"

    parse_selection "$reply"
}

# ============================================================================
# install
# ============================================================================

# Install a list of packages, splitting repo from AUR, then verify each one
# actually landed. Returns non-zero if anything is still missing afterwards.
install_packages() {
    local -a wanted=("$@")
    (( ${#wanted[@]} == 0 )) && return 0

    local -a repo=() aur=() pkg
    for pkg in "${wanted[@]}"; do
        if is_aur "$pkg"; then aur+=("$pkg"); else repo+=("$pkg"); fi
    done

    if (( ${#repo[@]} )); then
        note "pacman -S --needed  (${#repo[@]} packages)"
        sudo pacman -S --needed --noconfirm "${repo[@]}"
    fi

    if (( ${#aur[@]} )); then
        note "makepkg  (${#aur[@]} AUR packages: ${aur[*]})"
        for pkg in "${aur[@]}"; do
            aur_install "$pkg" || bad "makepkg failed for $pkg"
        done
    fi

    # --- verify -------------------------------------------------------------
    # pacman exits 0 in plenty of situations where a package did not install,
    # so ask the database rather than trusting the exit code.
    refresh_installed
    local -a failed=()
    for pkg in "${wanted[@]}"; do
        is_satisfied "$pkg" || failed+=("$pkg")
    done

    if (( ${#failed[@]} )); then
        bad "${#failed[@]} package(s) did not install: ${failed[*]}"
        mkdir -p "$STATE_DIR"
        printf '%s\n' "${failed[@]}" > "$STATE_DIR/failed-packages"
        note "recorded in $STATE_DIR/failed-packages - re-run this script to retry"
        return 1
    fi

    rm -f "$STATE_DIR/failed-packages"
    ok "${#wanted[@]} package(s) installed and verified"
    return 0
}

# ============================================================================
# AUR - no helper
#
# This setup needs exactly two AUR packages, so it builds them with makepkg
# directly instead of installing an AUR helper to do it.
#
# That is not just minimalism. The
#
#     paru: error while loading shared libraries: libalpm.so.15
#
# failure exists because AUR helpers link against pacman's C library: paru-bin
# is a prebuilt binary, pacman 7.x bumped the soname to libalpm.so.16, and the
# old binary stopped starting. Every helper written in Rust or Go has this
# same failure mode after a pacman upgrade. makepkg is part of pacman itself,
# so it cannot go out of sync with it, and nothing here needs a compiler
# toolchain that is not already pulled in by base-devel.
# ============================================================================

# Build and install one AUR package from its git repo.
aur_install() {
    local pkg="$1" tmp dir rc

    tmp="$(mktemp -d)" || return 1
    dir="$tmp/$pkg"

    if ! git clone --depth 1 "https://aur.archlinux.org/${pkg}.git" "$dir" >/dev/null 2>&1; then
        bad "could not clone $pkg from the AUR"
        rm -rf "$tmp"
        return 1
    fi

    # Some AUR packages are drop-in replacements for a repo package rather than
    # additions to it - i3lock-color provides the same `i3lock` binary with more
    # flags. pacman refuses to swap those silently: it asks "Remove i3lock?",
    # and under --noconfirm the answer is No, so the whole build fails at the
    # last step. Take the conflicts from .SRCINFO and deal with them up front.
    local -a blockers=()
    local c
    while read -r c; do
        [[ -z "$c" ]] && continue
        is_installed "$c" && blockers+=("$c")
    done < <(awk -F'=' '/^[[:space:]]*conflicts[[:space:]]*=/ {
                            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                            sub(/[<>=].*/, "", $2)
                            print $2
                        }' "$dir/.SRCINFO" 2>/dev/null)

    if (( ${#blockers[@]} )); then
        warn "$pkg replaces ${blockers[*]} - the same binary, with more features"
        if ! confirm "Remove ${blockers[*]} so $pkg can take over?"; then
            note "skipped $pkg"
            rm -rf "$tmp"
            return 1
        fi
        # -dd skips the dependency check: anything that depended on the old
        # package is satisfied again the moment the replacement lands.
        if ! sudo pacman -Rdd --noconfirm "${blockers[@]}"; then
            bad "could not remove ${blockers[*]}"
            rm -rf "$tmp"
            return 1
        fi
    fi

    (
        cd "$dir" &&
        # --needed so a re-run is a no-op; -s pulls any makedepends via pacman.
        makepkg -si --noconfirm --needed
    )
    rc=$?

    # Never leave the system with neither: if the replacement failed to build,
    # put back what was removed for it.
    if (( rc != 0 && ${#blockers[@]} )); then
        warn "$pkg failed to build - reinstalling ${blockers[*]}"
        sudo pacman -S --needed --noconfirm "${blockers[@]}" >/dev/null 2>&1 ||
            bad "could not reinstall ${blockers[*]} - do it by hand"
    fi

    rm -rf "$tmp"
    return $rc
}

# ============================================================================
# steps
# ============================================================================

do_update() {
    step "refreshing package databases"
    if (( ! DO_UPDATE )); then
        note "skipped (--no-update)"
        return 0
    fi
    if sudo pacman -Syu --noconfirm; then
        ok "system up to date"
    else
        warn "pacman -Syu failed - continuing, but installs may fail too"
    fi
}

do_packages() {
    refresh_installed
    build_pick_list

    local missing=0 i
    for i in "${!PICK_STATE[@]}"; do
        [[ "${PICK_STATE[$i]}" == "missing" ]] && missing=$((missing + 1))
    done

    step "packages"

    local -a chosen=()
    if (( missing == 0 && ! FORCE_REPAIR )); then
        ok "all ${#PICK_NAMES[@]} packages already installed"
        note "run with --repair to reinstall or add anything"
        return 0
    fi

    # A genuinely bare system has essentially nothing installed, and making you
    # page through 71 lines all saying "missing" to type "all" would be silly.
    # Anything less than that is a partial or repeat install, which is exactly
    # the case the picker exists for - so go by what is on the system, not by
    # whether a state file happens to exist.
    if (( ! FORCE_REPAIR && missing * 100 / ${#PICK_NAMES[@]} >= 90 )); then
        note "fresh system - installing all ${#PICK_NAMES[@]} packages"
        chosen=("${PICK_NAMES[@]}")
    else
        mapfile -t chosen < <(run_picker)
    fi

    if (( ${#chosen[@]} == 0 )); then
        note "nothing selected"
        return 0
    fi

    install_packages "${chosen[@]}"
}

do_services() {
    step "services"
    local svc rc=0
    for svc in NetworkManager.service bluetooth.service; do
        if [[ -z "$(systemctl list-unit-files --no-legend "$svc" 2>/dev/null)" ]]; then
            warn "$svc not present, skipping"
            continue
        fi
        sudo systemctl enable --now "$svc" >/dev/null 2>&1 ||
            { warn "could not enable $svc"; rc=1; }
    done

    systemctl --user enable --now pipewire.service pipewire-pulse.service \
        wireplumber.service >/dev/null 2>&1 ||
        { warn "could not enable the pipewire user services"; rc=1; }

    (( rc == 0 )) && ok "network, bluetooth and audio enabled"
    return 0
}

do_dotfiles() {
    step "dotfiles"

    if ! command -v stow >/dev/null; then
        bad "stow is not installed - skipping (re-run after installing it)"
        return 1
    fi

    mkdir -p "$HOME/.config"

    # Unstow first. An earlier run of this script (or any stow without
    # --no-folding) leaves ~/.config/polybar as a single symlink into the repo.
    # If that is still in place when the backup scan below runs, every path
    # under it resolves *through* the symlink and "backing up" a pre-existing
    # file would move the repo's own file out of the repo. Removing the links
    # first means the scan only ever sees genuinely foreign files.
    stow --dir="$REPO" --target="$HOME" --delete dotfiles >/dev/null 2>&1

    # stow refuses to overwrite real files, so move anything pre-existing aside.
    local backup moved=0 f rel target real
    backup="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
    while IFS= read -r -d '' f; do
        rel="${f#"$REPO/dotfiles/"}"
        target="$HOME/$rel"

        [[ -e "$target" ]] || continue
        [[ -L "$target" ]] && continue

        # Belt and braces for the case above: if the target resolves to
        # somewhere inside the repo, it is already ours and must never be moved.
        real="$(readlink -f -- "$target" 2>/dev/null)"
        [[ "$real" == "$REPO"/* ]] && continue

        mkdir -p "$backup/$(dirname "$rel")"
        mv -- "$target" "$backup/$rel"
        moved=$((moved + 1))
    done < <(find "$REPO/dotfiles" -type f -print0)

    (( moved > 0 )) && warn "moved $moved pre-existing config(s) to $backup"

    # --no-folding is load-bearing. Without it stow replaces ~/.config/kitty
    # with a single symlink into the repo, and theme_engine's generated
    # current-theme.conf would then be written inside the git tree. With it,
    # every directory is real and only the files are symlinks, so generated
    # colour files sit beside the configs that include them and stay out of git.
    if stow --dir="$REPO" --target="$HOME" --restow --no-folding dotfiles; then
        ok "dotfiles linked into \$HOME"
    else
        bad "stow failed"
        return 1
    fi

    # Make sure the scripts are executable.
    #
    # i3 launches theme_init.sh with exec_always. If that file is not +x, i3
    # gets "Permission denied", says nothing about it, and you boot to no
    # wallpaper and no bar with no clue why. git does track the execute bit,
    # but only if it was set when the file was committed - and an editor that
    # writes a new file gives it 644. Setting it here means a wrong mode in
    # the repo cannot produce a silently broken desktop.
    local script fixed=0
    while IFS= read -r script; do
        [[ -x "$script" ]] && continue
        chmod +x "$script" && fixed=$((fixed + 1))
    done < <(find "$REPO/dotfiles" -type f \( -name '*.sh' -o -name 'checkupdates' \))
    (( fixed > 0 )) && note "made $fixed script(s) executable"

    # ranger's preview script is shipped by ranger itself; copy it in rather
    # than vendoring 300 lines of someone else's shell into this repo.
    if command -v ranger >/dev/null && [[ ! -f "$HOME/.config/ranger/scope.sh" ]]; then
        ranger --copy-config=scope >/dev/null 2>&1 &&
            note "installed ranger's scope.sh preview script"
    fi
}

XINITRC_TAG="# written by postinstall.sh - \`startx\` reads this"

do_xinitrc() {
    step "X session"

    # An .xinitrc we wrote gets rewritten, so an existing install picks up
    # changes to the block below. Anything else is somebody's own session
    # setup and is left alone.
    if [[ -e "$HOME/.xinitrc" && ! -L "$HOME/.xinitrc" ]] &&
       ! grep -qF "$XINITRC_TAG" "$HOME/.xinitrc"; then
        note "~/.xinitrc already exists and is not ours, leaving it alone"
        note "for Qt apps to follow the theme it needs: export QT_QPA_PLATFORMTHEME=gtk3"
        return 0
    fi

    cat > "$HOME/.xinitrc" <<EOF
#!/bin/sh
$XINITRC_TAG

[ -f ~/.Xresources ] && xrdb -merge ~/.Xresources
[ -f ~/.cache/theme/colors.Xresources ] && xrdb -merge ~/.cache/theme/colors.Xresources

# Qt draws with its own palette and knows nothing about the wallpaper. A
# platform theme plugin is what bridges that, and it has to be an environment
# variable because Qt reads it before any app code runs.
#
# qt5ct/qt6ct are preferred when installed: the theme engine writes them an
# explicit palette, so every Qt widget gets an exact colour. Otherwise the
# gtk3 plugin makes Qt read the GTK theme instead, which the engine also
# generates - fewer packages, same colours.
if [ -n "\$(command -v qt6ct)" ]; then
    export QT_QPA_PLATFORMTHEME=qt6ct
elif [ -n "\$(command -v qt5ct)" ]; then
    export QT_QPA_PLATFORMTHEME=qt5ct
else
    export QT_QPA_PLATFORMTHEME=gtk3
fi

# Java's AWT toolkit assumes a reparenting window manager and draws blank
# windows under i3 without this.
export _JAVA_AWT_WM_NONREPARENTING=1

exec i3
EOF
    chmod +x "$HOME/.xinitrc"
    ok "wrote ~/.xinitrc (startx -> i3, Qt pointed at the generated theme)"
}

# Generate a plain dark gradient to use as a wallpaper when there are none.
#
# This is not decoration. i3's config does `include colors.conf`, and that file
# only exists once theme_engine has run against some image. Shipping a fallback
# means a first boot lands on a themed desktop instead of an i3 config error.
make_fallback_wallpaper() {
    local out="$1"
    python - "$out" <<'EOF' 2>/dev/null
import sys
import numpy as np, cv2
h, w = 1080, 1920
y = np.linspace(0, 1, h)[:, None]
x = np.linspace(0, 1, w)[None, :]
t = (0.65 * y + 0.35 * x)
# BGR, deep blue-violet to near-black.
img = np.stack([
    28 + 42 * (1 - t),
    18 + 24 * (1 - t),
    24 + 46 * (1 - t),
], axis=-1).astype(np.uint8)
cv2.imwrite(sys.argv[1], img)
EOF
    [[ -s "$out" ]]
}

do_theme() {
    step "desktop palette"

    local wdir="$HOME/.wallpaper/my_collection"
    mkdir -p "$wdir" "$HOME/.wallpaper/bing" "$HOME/Pictures/maim"

    local count
    count=$(find -L "$wdir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' \
            -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | wc -l)

    if (( count == 0 )); then
        warn "no wallpapers in ~/.wallpaper/my_collection"
        note "the whole colour scheme is derived from the wallpaper, so I need one"
        if make_fallback_wallpaper "$wdir/default-gradient.png"; then
            note "generated a placeholder gradient to theme from"
            note "drop your own images in $wdir and press \$mod+Shift+w"
        else
            bad "could not generate a placeholder - put an image in $wdir and run:"
            note "  ~/.config/i3/script/theme_init.sh --my_collection"
            return 1
        fi
    else
        note "$count wallpaper(s) found"
    fi

    # Generate the palette now, without the reload half of theme_init.sh:
    # nothing is running yet, and i3 needs colors.conf to exist before startx.
    local engine="$HOME/.config/polybar/shades/theme_engine/main.py"
    if [[ ! -f "$engine" ]]; then
        bad "theme engine not found at $engine - did the dotfiles step run?"
        return 1
    fi

    local wall
    wall=$(find -L "$wdir" -type f \( -iname '*.jpg' -o -iname '*.jpeg' \
           -o -iname '*.png' -o -iname '*.webp' \) 2>/dev/null | head -n 1)

    mkdir -p "$HOME/.cache/theme"
    if python "$engine" "$wall" -o "$HOME/.cache/theme" >/dev/null 2>&1; then
        printf '%s\n' "$wall" > "$HOME/.cache/theme/wallpaper"
        ok "palette generated - i3, polybar, rofi, kitty, dunst, gtk, nvim and the prompt all read it"
    else
        bad "palette generation failed"
        note "run it by hand to see why:"
        note "  python $engine \"$wall\""
        return 1
    fi

    # Firefox has no profile until it has been run once, so the engine has
    # nothing to write into on a fresh machine. Say it here too - the engine's
    # own message is swallowed by the redirect above.
    if command -v firefox >/dev/null && [[ ! -d "$HOME/.mozilla/firefox" ]]; then
        note "firefox has no profile yet - run it once, then \$mod+Shift+w themes it"
    fi

    # The same first-boot problem colors.conf has, for the other generated
    # include in i3's config. i3 parses `include monitors.conf` while it
    # starts; monitors.sh only runs afterwards as exec_always, so on a first
    # boot the file does not exist yet. i3 tolerates that silently, which is
    # worse than it sounds - the workspace assignments are simply absent until
    # theme_init.sh's `i3-msg reload` lands a second later.
    #
    # The placeholder assigns nothing on purpose: real output names need
    # xrandr against a running X server, and there is not one yet. It only has
    # to make the first parse complete. monitors.sh overwrites it at every i3
    # start with the layout that is actually plugged in.
    local mon="$HOME/.config/i3/monitors.conf"
    if [[ -d "$HOME/.config/i3" && ! -e "$mon" ]]; then
        cat > "$mon" <<'EOF'
# Placeholder written by postinstall.sh so i3's `include monitors.conf` has
# something to read on the very first startx.
#
# It is empty because working out which outputs exist needs xrandr against a
# running X server. monitors.sh replaces this with the real
# `workspace N output ...` lines at every i3 start, and on $mod+Shift+m.
EOF
        note "wrote a placeholder ~/.config/i3/monitors.conf for the first startx"
    fi
}

# ============================================================================
# run
# ============================================================================

usage() {
    cat <<EOF
postinstall.sh - build the i3 desktop layer on top of Arch

  --repair      show the package picker even if nothing is missing
  --yes         answer every prompt with the default (non-interactive)
  --no-update   skip the initial pacman -Syu
  --help        this
EOF
}

while (( $# )); do
    case "$1" in
        --repair)    FORCE_REPAIR=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
        --no-update) DO_UPDATE=0 ;;
        --help|-h)   usage; exit 0 ;;
        *)           die "unknown option: $1  (try --help)" ;;
    esac
    shift
done

[[ $EUID -eq 0 ]] && die "run this as your normal user, not root (it uses sudo where it needs to)"
command -v pacman >/dev/null || die "this is not an Arch system"
[[ -d "$REPO/dotfiles" ]] || die "expected $REPO/dotfiles - is the repo complete?"

blank
printf '%s  postinstall%s  building the i3 desktop on top of Arch\n' "$B" "$N"
blank
printf '  %srepo%s   %s\n' "$D" "$N" "$REPO"
printf '  %suser%s   %s\n' "$D" "$N" "$(whoami)"
printf '  %spacman%s %s\n' "$D" "$N" "$(pacman -Q pacman 2>/dev/null | awk '{print $2}')"

if [[ -f "$LAST_RUN" ]]; then
    printf '  %slast%s   %s\n' "$D" "$N" "$(cat "$LAST_RUN")"
    blank
    say "  This has run before, so I'll only touch what is missing or broken."
else
    blank
    say "  I'll install the X server, i3, polybar, the apps and fonts, link this"
    say "  repo's dotfiles into your home directory, and generate the desktop"
    say "  colour scheme from a wallpaper."
fi

if [[ -f "$STATE_DIR/failed-packages" ]]; then
    blank
    warn "last run left these unfinished: $(tr '\n' ' ' < "$STATE_DIR/failed-packages")"
fi

if ! confirm "Start?"; then
    blank; say "  Nothing done."; blank
    exit 0
fi

FAILURES=0

do_update
do_packages  || FAILURES=$((FAILURES + 1))
do_services  || FAILURES=$((FAILURES + 1))
do_dotfiles  || FAILURES=$((FAILURES + 1))
do_xinitrc   || FAILURES=$((FAILURES + 1))
do_theme     || FAILURES=$((FAILURES + 1))

mkdir -p "$STATE_DIR"
date '+%Y-%m-%d %H:%M' > "$LAST_RUN"

# --- done -------------------------------------------------------------------
blank
if (( FAILURES == 0 )); then
    printf '%s  done%s  start the desktop with %sstartx%s\n' "$B" "$N" "$B" "$N"
else
    printf '%s  finished with %d problem(s)%s\n' "$Y" "$FAILURES" "$N"
    say "  Re-run this script to retry - it will only touch what is still missing."
fi
# A paru left over from an older setup is dead weight now that nothing uses it,
# and if it is the broken build it will keep failing confusingly. Say so once,
# but do not remove packages behind the user's back.
if command -v paru >/dev/null 2>&1; then
    if ldd "$(command -v paru)" 2>/dev/null | grep -q 'not found'; then
        warn "paru is installed but broken (missing $(ldd "$(command -v paru)" 2>/dev/null | awk '/not found/{print $1; exit}'))"
        note "nothing here uses it any more - remove it with: sudo pacman -Rns paru-bin paru"
    fi
fi

blank
say "  ${D}notes${N}"
say "    ${D}\$mod+Shift+w${N}  new wallpaper, and the whole desktop re-themes from it"
say "    ${D}\$mod+n${N}        ranger"
say "    ${D}--repair${N}      re-run with this to pick packages to reinstall"
say "    ${D}neovim${N}        bootstraps lazy.nvim and its plugins on first launch"
say "    ${D}dotfiles${N}      edit them in $REPO/dotfiles, changes apply immediately"
blank
