#!/bin/bash


# Parse the first command-line argument
case "$1" in
    --bing)
	$HOME/.config/i3/script/download_wallpaper.sh
        WALLPAPER_PATH=$(find "$HOME/.wallpaper/bing" -type f | shuf -n 1)
        ;;
    --my_collection)
        WALLPAPER_PATH=$(find "$HOME/.wallpaper/my_collection" -type f | shuf -n 1)
        ;;
    *)
        echo "Usage: $0 [ --bing | --my_collection ]"
        exit 1
        ;;
esac

# Generate colors with Python script 
python "$HOME/.config/polybar/shades/theme_engine/main.py" "$WALLPAPER_PATH" -o "$HOME/.config/polybar/shades/color"

# Set the wallpaper
feh --bg-scale "$WALLPAPER_PATH"

# Launch the Polybar shades
"$HOME/.config/polybar/shades/launch.sh"
