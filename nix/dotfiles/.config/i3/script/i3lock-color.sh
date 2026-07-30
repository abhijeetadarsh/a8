#!/bin/sh

# Dracula theme colors
BACKGROUND='#282a36ff'
BAR_COLOR='#44475aff'
KEYHL_COLOR='#50fa7bff'
TIME_COLOR='#8be9fdff'
DATE_COLOR='#bd93f9ff'
RINGVER_COLOR='#50fa7bff'
RINGWRONG_COLOR='#ff5555ff'
STATUS_COLOR='#f8f8f2ff'
VERIF_COLOR='#f8f8f2ff'
WRONG_COLOR='#ff5555ff'

i3lock \
--color=$BACKGROUND \
--bar-indicator \
--bar-pos y+h \
--bar-direction 1 \
--bar-max-height 50 \
--bar-base-width 50 \
--bar-color $BAR_COLOR \
--keyhl-color $KEYHL_COLOR \
--bar-periodic-step 50 \
--bar-step 50 \
--redraw-thread \
\
--clock \
--force-clock \
--time-str="%I:%M %p" \
--time-pos x+5:y+h-110 \
--time-color $TIME_COLOR \
--date-pos tx+5:ty+45 \
--date-color $DATE_COLOR \
--date-align 1 \
--time-align 1 \
--ringver-color $RINGVER_COLOR \
--ringwrong-color $RINGWRONG_COLOR \
--status-pos x+5:y+h-16 \
--verif-align 0 \
--wrong-align 0 \
--verif-color $VERIF_COLOR \
--wrong-color $WRONG_COLOR \
--time-size=80 \
--date-size=40 \
\
--verif-text="VERIFYING..." \
--wrong-text="INVALID! CREDENTIAL" \
--noinput-text=""
#--modif-pos -50:-50 \
