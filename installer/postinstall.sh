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
# It is safe to re-run: pacman skips what is already installed and stow
# re-links what is already linked.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- colors -----------------------------------------------------------------
if [[ -t 1 ]]; then
    B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; N=$'\e[0m'
else
    B=''; G=''; Y=''; R=''; N=''
fi
say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s  !!%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '%s  xx%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
head_() { printf '\n%s== %s ==%s\n' "$B" "$*" "$N"; }

# ============================================================================
# packages
# ============================================================================

# --- the display server + session -------------------------------------------
# These are the pieces that must be system packages; everything visual sits on
# top of them.
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
    i3-wm i3status i3lock
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
    kitty alacritty       # kitty is $mod+Return; alacritty is also configured
    starship eza          # .bashrc: prompt + `ls` alias
    neovim
    ripgrep fd fzf        # telescope / grep
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
    papirus-icon-theme            # polybar's updates.sh notification icon
)

# --- polybar's theme_engine (wallpaper -> colorscheme) ----------------------
# Only needed for theme_init.sh, which the i3 config runs at startup.
PKGS_THEME=( python python-numpy python-scikit-learn python-opencv python-matplotlib )

# --- AUR --------------------------------------------------------------------
# jump      - the `j` command in .bashrc
# i3lock-color - used by .config/i3/script/i3lock-color.sh
AUR_PKGS=( jump i3lock-color )

# ============================================================================
# run
# ============================================================================

[[ $EUID -eq 0 ]] && die "run this as your normal user, not root (it uses sudo where needed)"
command -v pacman >/dev/null || die "this is not an Arch system"
[[ -d "$REPO/dotfiles" ]] || die "expected $REPO/dotfiles - is the repo complete?"

say ""
say "${B}  postinstall${N} - building the user layer on top of Arch"
info "repo: $REPO"

# --- 1. sync ----------------------------------------------------------------
head_ "refreshing package databases"
sudo pacman -Syu --noconfirm
ok "system up to date"

# --- 2. repo packages -------------------------------------------------------
head_ "installing packages from the official repos"
ALL=( "${PKGS_X[@]}" "${PKGS_AUDIO[@]}" "${PKGS_NET[@]}" "${PKGS_I3[@]}"
      "${PKGS_SHOT[@]}" "${PKGS_TOOLS[@]}" "${PKGS_APPS[@]}" "${PKGS_FONTS[@]}"
      "${PKGS_THEME[@]}" )
info "${#ALL[@]} packages"
sudo pacman -S --needed --noconfirm "${ALL[@]}"
ok "repo packages installed"

# --- 3. AUR helper ----------------------------------------------------------
head_ "AUR"
if command -v paru >/dev/null; then
    ok "paru already installed"
else
    info "building paru from the AUR (this compiles, give it a few minutes)"
    tmp="$(mktemp -d)"
    git clone --depth 1 https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    ( cd "$tmp/paru-bin" && makepkg -si --noconfirm )
    rm -rf "$tmp"
    ok "paru installed"
fi

info "installing AUR packages: ${AUR_PKGS[*]}"
paru -S --needed --noconfirm "${AUR_PKGS[@]}" || \
    warn "an AUR package failed - not fatal, see the list above and retry by hand"

# --- 4. services ------------------------------------------------------------
head_ "services"
sudo systemctl enable --now NetworkManager.service
sudo systemctl enable --now bluetooth.service
systemctl --user enable --now pipewire.service pipewire-pulse.service wireplumber.service
ok "network, bluetooth and audio enabled"

# --- 5. dotfiles ------------------------------------------------------------
head_ "dotfiles"

# Make sure ~/.config exists so stow descends into it and links the individual
# programs, rather than folding the whole tree into one ~/.config symlink.
mkdir -p "$HOME/.config"

# stow refuses to overwrite real files, so move anything pre-existing aside.
backup="$HOME/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
moved=0
while IFS= read -r -d '' f; do
    rel="${f#"$REPO/dotfiles/"}"
    target="$HOME/$rel"
    if [[ -e "$target" && ! -L "$target" ]]; then
        mkdir -p "$backup/$(dirname "$rel")"
        mv "$target" "$backup/$rel"
        moved=$((moved + 1))
    fi
done < <(find "$REPO/dotfiles" -type f -print0)

if (( moved > 0 )); then
    warn "moved $moved pre-existing config(s) to $backup"
fi

stow --dir="$REPO" --target="$HOME" --restow dotfiles
ok "dotfiles linked into \$HOME"

# --- 6. xinitrc -------------------------------------------------------------
head_ "X session"
if [[ -e "$HOME/.xinitrc" && ! -L "$HOME/.xinitrc" ]]; then
    info "~/.xinitrc already exists, leaving it alone"
else
    cat > "$HOME/.xinitrc" <<'EOF'
#!/bin/sh
# written by postinstall.sh - `startx` reads this

[ -f ~/.Xresources ] && xrdb -merge ~/.Xresources

exec i3
EOF
    chmod +x "$HOME/.xinitrc"
    ok "wrote ~/.xinitrc (startx -> i3)"
fi

# --- 7. wallpapers ----------------------------------------------------------
# The i3 config runs theme_init.sh --my_collection at startup, which picks a
# random file from here. Without it, i3 starts with no wallpaper and no bar.
head_ "wallpapers"
mkdir -p "$HOME/.wallpaper/my_collection" "$HOME/.wallpaper/bing" "$HOME/Pictures/maim"
if [[ -z "$(ls -A "$HOME/.wallpaper/my_collection")" ]]; then
    warn "~/.wallpaper/my_collection is empty"
    info "theme_init.sh picks a random wallpaper from there and generates the"
    info "polybar colorscheme from it - drop some images in before running startx,"
    info "or run: ~/.config/i3/script/theme_init.sh --bing"
else
    ok "wallpapers present"
fi

# --- done -------------------------------------------------------------------
head_ "done"
say ""
info "start the desktop with:  ${B}startx${N}"
say ""
info "notes:"
info "  - neovim will bootstrap lazy.nvim and its plugins on first launch"
info "  - edit a config in $REPO/dotfiles and it applies immediately (stow symlinks)"
info "  - re-run this script any time you add packages to it"
say ""
