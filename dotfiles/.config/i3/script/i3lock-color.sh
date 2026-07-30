#!/usr/bin/env bash
#
# Lock screen, coloured from the current wallpaper palette.
#
# theme_engine writes ~/.cache/theme/colors.sh on every wallpaper change. The
# defaults below only apply if the palette has never been generated, so the
# lock screen still works on a fresh system.

PALETTE="$HOME/.cache/theme/colors.sh"
# shellcheck source=/dev/null
[[ -f "$PALETTE" ]] && . "$PALETTE"

# i3lock wants #rrggbbaa; the palette stores #rrggbb.
a() { printf '%sff' "${1:-$2}"; }

BACKGROUND=$(a "${THEME_BASE:-}"      "#1e1e2e")
BAR_COLOR=$(a "${THEME_SURFACE1:-}"   "#313244")
KEYHL_COLOR=$(a "${THEME_ACCENT:-}"   "#89b4fa")
TIME_COLOR=$(a "${THEME_TEXT:-}"      "#cdd6f4")
DATE_COLOR=$(a "${THEME_SUBTEXT:-}"   "#bac2de")
RINGVER_COLOR=$(a "${THEME_GREEN:-}"  "#a6e3a1")
RINGWRONG_COLOR=$(a "${THEME_RED:-}"  "#f38ba8")
VERIF_COLOR=$(a "${THEME_TEXT:-}"     "#cdd6f4")
WRONG_COLOR=$(a "${THEME_RED:-}"      "#f38ba8")

i3lock \
--color="$BACKGROUND" \
--bar-indicator \
--bar-pos y+h \
--bar-direction 1 \
--bar-max-height 50 \
--bar-base-width 50 \
--bar-color "$BAR_COLOR" \
--keyhl-color "$KEYHL_COLOR" \
--bar-periodic-step 50 \
--bar-step 50 \
--redraw-thread \
\
--clock \
--force-clock \
--time-str="%I:%M %p" \
--time-pos x+5:y+h-110 \
--time-color "$TIME_COLOR" \
--date-pos tx+5:ty+45 \
--date-color "$DATE_COLOR" \
--date-align 1 \
--time-align 1 \
--ringver-color "$RINGVER_COLOR" \
--ringwrong-color "$RINGWRONG_COLOR" \
--status-pos x+5:y+h-16 \
--verif-align 0 \
--wrong-align 0 \
--verif-color "$VERIF_COLOR" \
--wrong-color "$WRONG_COLOR" \
--time-size=80 \
--date-size=40 \
\
--verif-text="VERIFYING..." \
--wrong-text="INVALID CREDENTIAL" \
--noinput-text=""
