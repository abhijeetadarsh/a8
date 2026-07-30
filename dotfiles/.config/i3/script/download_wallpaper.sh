#!/bin/bash

# Define the wallpaper directory and retry parameters
WALLPAPER_DIR="$HOME/.wallpaper/bing/"
MAX_RETRIES=10
RETRY_DELAY=1

# Ensure the directory exists
mkdir -p "$WALLPAPER_DIR"

# Step 1: Clear the wallpaper directory
find "$WALLPAPER_DIR" -type f -delete
echo "Wallpaper directory cleared."

# Step 2: Download the Bing wallpaper with retries
download_success=0
for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
    echo "Attempt $attempt to download Bing wallpaper..."
    if /usr/local/bin/bing-wallpaper -o "$WALLPAPER_DIR/"; then
        echo "Bing wallpaper downloaded successfully."
        download_success=1
        break
    else
        echo "Download failed. Retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
    fi
done

if [ $download_success -eq 0 ]; then
    echo "Failed to download Bing wallpaper after $MAX_RETRIES attempts."
    exit 1
fi

