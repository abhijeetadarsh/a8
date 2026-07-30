#!/bin/bash

# Define Dracula theme colors with a purple background
BACKGROUND='#44475aff'   # Solid purple background
CLEAR='#bd93f9ff'        # Use the same purple for the clear color
DEFAULT='#50fa7bff'      # Green for the ring (Dracula Green)
TEXT='#f8f8f2ff'         # Off-white for the text (Dracula Foreground)
WRONG='#ff5555ff'        # Red for wrong input (Dracula Red)
VERIFYING='#ff79c6ff'    # Pink for verifying (Dracula Pink)

# Run i3lock with the defined colors, avoiding transparency
i3lock \
--radius=200 \
--color=$BACKGROUND	     \
--insidever-color=$CLEAR     \
--ringver-color=$VERIFYING   \
\
--insidewrong-color=$CLEAR   \
--ringwrong-color=$WRONG     \
\
--inside-color=$BACKGROUND   \
--ring-color=$DEFAULT        \
--line-color=$BACKGROUND     \
--separator-color=$DEFAULT   \
\
--verif-color=$TEXT          \
--wrong-color=$TEXT          \
--time-color=$TEXT           \
--date-color=$TEXT           \
--layout-color=$TEXT         \
--keyhl-color=$WRONG         \
--bshl-color=$WRONG          \
\
--screen 1                   \
--clock                      \
--indicator                  \
--time-str="%I:%M %p"     \
\
--time-size=80		        \
--date-size=40		        \
--layout-size=60		\
--verif-size=60		\
--wrong-size=60		\
--greeter-size=60		\
--time-pos="ix:iy"              \
--date-pos="tx:ty+100"          \
--verif-pos="tx:ty+100"		\
--wrong-pos="tx:ty+100"		\
--no-input-pos="tx:ty+100"		\
--greeter-pos="tx:ty+100"		\
--verif-text="verifying"
