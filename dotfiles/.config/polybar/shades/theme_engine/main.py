import configparser
import os
import sys
import argparse
from sklearn.cluster import KMeans
import cv2


def extract_colors(image_path):
    """
    Extract a color palette from the given image.
    """
    import colorsys

    image = cv2.imread(image_path)
    image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)
    image = image.reshape((image.shape[0] * image.shape[1], 3))

    # Perform clustering to find main colors
    n_clusters = 5  # Extract 5 main colors
    clt = KMeans(n_clusters=n_clusters)
    clt.fit(image)

    # Sort cluster centers by luminance (brightness)
    def luminance(color):
        return 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]

    centers = sorted(clt.cluster_centers_, key=luminance)

    # Function to tweak saturation for shades
    def tweak_saturation(rgb, factor):
        r, g, b = [x / 255.0 for x in rgb]
        h, l, s = colorsys.rgb_to_hls(r, g, b)
        s = min(max(s * factor, 0), 1)
        r, g, b = colorsys.hls_to_rgb(h, l, s)
        return [int(x * 255) for x in (r, g, b)]

    # Create the palette
    palette = {
        "background": "#{:02x}{:02x}{:02x}".format(*[int(c) for c in centers[0]]),
        "foreground": "#{:02x}{:02x}{:02x}".format(*[int(c) for c in centers[-1]]),
        "foreground-alt": "#{:02x}{:02x}{:02x}".format(*[int(c) for c in centers[-2]]),
    }

    shades = (
        [
            tweak_saturation(centers[1], factor)
            for factor in [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5]
        ]
        # + [tweak_saturation(centers[1], factor) for factor in [1, 1.5, 2, 2.5]]
        # + [tweak_saturation(centers[3], factor) for factor in [1, 1.5]]
    )
    for i, shade in enumerate(shades, start=1):
        palette[f"shade{9 - i}"] = "#{:02x}{:02x}{:02x}".format(*shade)

    return palette


def save_palette_to_ini(palette, output_path="colors.ini"):
    """
    Save the color palette to an INI file.
    """
    if not palette:
        return

    config = configparser.ConfigParser(allow_no_value=True)
    config.optionxform = str  # Preserve case sensitivity

    config["color"] = {
        "; main colors": None,
        "background": palette["background"],
        "foreground": palette["foreground"],
        "foreground-alt": palette["foreground-alt"],
        "\n; shades": None,
    }

    for i in range(1, 9):
        config["color"][f"shade{i}"] = palette[f"shade{i}"]

    with open(output_path, "w") as configfile:
        config.write(configfile)

    print(f"Palette saved to {output_path}")


def save_palette_to_rasi(palette, output_path="colors.rasi"):
    """
    Save the color palette to a RASI file.
    """
    if not palette:
        return

    rasi_content = "/* colors */\n\n* {\n"
    rasi_content += f"  al:    #00000000;\n"
    rasi_content += f"  bg:    {palette['background']}FF;\n"
    rasi_content += f"  bg1:   {palette.get('shade1', '#000000')}FF;\n"
    rasi_content += f"  bg2:   {palette.get('shade2', '#000000')}FF;\n"
    rasi_content += f"  bg3:   {palette.get('shade3', '#000000')}FF;\n"
    rasi_content += f"  bg4:   {palette.get('shade4', '#000000')}FF;\n"
    rasi_content += f"  fg:    {palette['foreground']}FF;\n"
    rasi_content += "}\n"

    with open(output_path, "w") as rasi_file:
        rasi_file.write(rasi_content)

    print(f"RASI palette saved to {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Generate color palette from an image")
    parser.add_argument("image_path", help="Path to the image file")
    parser.add_argument(
        "-o",
        "--output-dir",
        default=".",
        help="Output directory for generated files (default: current directory)",
    )

    args = parser.parse_args()

    # Check if image exists
    if not os.path.exists(args.image_path):
        print(f"Error: Image file '{args.image_path}' not found")
        sys.exit(1)

    # Create output directory if it doesn't exist
    os.makedirs(args.output_dir, exist_ok=True)

    # Generate paths for output files
    ini_path = os.path.join(args.output_dir, "out.ini")
    rasi_path = os.path.join(args.output_dir, "out.rasi")

    # Extract and save the palette
    palette = extract_colors(args.image_path)
    # print(palette)
    if palette:
        save_palette_to_ini(palette, ini_path)
        save_palette_to_rasi(palette, rasi_path)


if __name__ == "__main__":
    main()
