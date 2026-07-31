#!/usr/bin/env python
"""
theme_engine - derive one palette from the current wallpaper and write it out
for every program on the desktop.

    main.py /path/to/wallpaper.jpg

Colour extraction is KMeans over the image, same as before. What changed is
what happens afterwards: palette.py turns the raw clusters into a palette with
enforced contrast, and writers.py emits it for polybar, rofi, i3, kitty, dunst,
gtk 2/3/4, Qt, Firefox, nvim, starship, xrdb and the shell.

Nothing here reloads anything - that is theme_init.sh's job.
"""

import argparse
import configparser
import glob
import os
import shutil
import sys

import cv2
import numpy as np
from sklearn.cluster import KMeans

import palette as palette_mod
import writers

# How many colours to cluster the image into. More than the palette needs, so
# there is something to choose between when picking a background and an accent.
N_CLUSTERS = 8

# Images get downscaled before clustering. KMeans over 8 megapixels takes
# seconds and produces the same centres as KMeans over 160k pixels.
MAX_PIXELS = 400 * 400


def extract_clusters(image_path, n_clusters=N_CLUSTERS, seed=0):
    """Return [(rgb_triple_0_to_1, weight), ...] sorted by weight descending."""
    image = cv2.imread(image_path)
    if image is None:
        raise ValueError(f"could not read image: {image_path}")

    image = cv2.cvtColor(image, cv2.COLOR_BGR2RGB)

    h, w = image.shape[:2]
    if h * w > MAX_PIXELS:
        scale = (MAX_PIXELS / (h * w)) ** 0.5
        image = cv2.resize(
            image,
            (max(1, int(w * scale)), max(1, int(h * scale))),
            interpolation=cv2.INTER_AREA,
        )

    pixels = image.reshape(-1, 3).astype(np.float32)

    # A photo can be 80% near-black sky. Those pixels are real, but clustering
    # on them wastes most of the clusters describing shades of nothing, so drop
    # the extremes - unless that is genuinely all the image has.
    lum = pixels @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    mid = pixels[(lum > 12) & (lum < 243)]
    if len(mid) > len(pixels) * 0.05:
        pixels = mid

    clt = KMeans(n_clusters=min(n_clusters, len(pixels)), n_init=4, random_state=seed)
    labels = clt.fit_predict(pixels)

    counts = np.bincount(labels, minlength=len(clt.cluster_centers_))
    total = counts.sum()

    clusters = [
        (tuple(float(c) / 255.0 for c in center), float(count) / total)
        for center, count in zip(clt.cluster_centers_, counts)
    ]
    clusters.sort(key=lambda c: c[1], reverse=True)
    return clusters


def _guard_ok(guard):
    """Whether a target's guard says the program is present. See build_targets."""
    if guard is None:
        return True
    if callable(guard):
        return bool(guard())
    return os.path.isdir(guard)


def firefox_profiles(home):
    """Every Firefox profile directory on the machine.

    profiles.ini is the authority - a profile can live anywhere and there can
    be several - but it only appears after Firefox has been run once. Falling
    back to a glob means a profile created by an installer we did not see
    still gets themed.
    """
    root = os.path.join(home, ".mozilla", "firefox")
    if not os.path.isdir(root):
        return []

    found = []
    ini = os.path.join(root, "profiles.ini")
    if os.path.isfile(ini):
        parser = configparser.ConfigParser()
        try:
            parser.read(ini)
        except configparser.Error:
            parser = None
        if parser:
            for section in parser.sections():
                if not section.lower().startswith("profile"):
                    continue
                path = parser[section].get("Path")
                if not path:
                    continue
                # IsRelative=0 means Path is already absolute.
                if parser[section].get("IsRelative", "1") == "0":
                    found.append(path)
                else:
                    found.append(os.path.join(root, path))

    if not found:
        found = [d for d in glob.glob(os.path.join(root, "*.*")) if os.path.isdir(d)]

    return [d for d in dict.fromkeys(found) if os.path.isdir(d)]


def build_targets(cache, cfg, home):
    """(label, writer, output path, guard).

    The guard is how a program that is not installed gets skipped. It is
    either a directory that must exist - stow only creates ~/.config/dunst if
    dunst's config is in the repo, so a missing directory means "nothing here
    consumes this" rather than an error - or a callable returning whether to
    write, for programs with no config directory of their own until they are
    first run.
    """
    targets = [
        # absolute-path consumers - always written
        ("shell",      writers.shell,      f"{cache}/colors.sh",           None),
        ("json",       writers.json_dump,  f"{cache}/colors.json",         None),
        ("nvim",       writers.nvim,       f"{cache}/nvim.lua",            None),
        ("starship",   writers.starship,   f"{cache}/starship.toml",       None),
        ("xresources", writers.xresources, f"{cache}/colors.Xresources",   None),
        # include-a-sibling consumers - written next to the program's config
        ("polybar",  writers.polybar, f"{cfg}/polybar/shades/color/out.ini",   f"{cfg}/polybar/shades"),
        # polybar's own launcher/powermenu menus import out.rasi, so the bar's
        # popups match the bar rather than shipping a second palette.
        ("polybar-rofi", writers.rofi, f"{cfg}/polybar/shades/color/out.rasi", f"{cfg}/polybar/shades"),
        ("rofi",     writers.rofi,    f"{cfg}/rofi/colors.rasi",               f"{cfg}/rofi"),
        ("i3",       writers.i3,      f"{cfg}/i3/colors.conf",                 f"{cfg}/i3"),
        ("kitty",    writers.kitty,   f"{cfg}/kitty/current-theme.conf",       f"{cfg}/kitty"),
        ("dunst",    writers.dunst,   f"{cfg}/dunst/dunstrc.d/99-theme.conf",  f"{cfg}/dunst"),
        ("gtk3",     writers.gtk,     f"{cfg}/gtk-3.0/gtk.css",                f"{cfg}/gtk-3.0"),
        ("gtk4",     writers.gtk,     f"{cfg}/gtk-4.0/gtk.css",                f"{cfg}/gtk-4.0"),
        # GTK2 has no config directory to guard on, and the file is tiny.
        ("gtk2",     writers.gtk2,    f"{home}/.gtkrc-2.0",                    None),
    ]

    # Qt. qt5ct/qt6ct create their own config directory on first run, so the
    # guard is the binary rather than a directory - without the tool installed
    # the files would be read by nothing.
    for tool in ("qt5ct", "qt6ct"):
        targets += [
            (f"{tool}-colors", writers.qt_colors,
             f"{cfg}/{tool}/colors/wallpaper.conf", lambda t=tool: shutil.which(t)),
            (tool, writers.qtct, f"{cfg}/{tool}/{tool}.conf",
             lambda t=tool: shutil.which(t)),
        ]

    # Firefox keeps everything per profile, so this is one target per profile
    # rather than one for the browser. The writer takes the profile directory
    # and produces the three files inside it that Firefox needs.
    for profile in firefox_profiles(home):
        targets.append(
            (f"firefox:{os.path.basename(profile)}", writers.firefox, profile, None)
        )

    return targets


def main():
    ap = argparse.ArgumentParser(
        description="Generate a desktop-wide colour palette from an image"
    )
    ap.add_argument("image_path", help="path to the wallpaper")
    ap.add_argument(
        "-o", "--output-dir",
        default=os.path.expanduser("~/.cache/theme"),
        help="where the absolute-path outputs go (default: ~/.cache/theme)",
    )
    ap.add_argument(
        "-c", "--config-dir",
        default=os.path.expanduser("~/.config"),
        help="config root for the in-place outputs (default: ~/.config)",
    )
    ap.add_argument(
        "-H", "--home-dir",
        default=os.path.expanduser("~"),
        help="home directory, for ~/.gtkrc-2.0 and Firefox profiles (default: ~)",
    )
    ap.add_argument(
        "--light", action="store_true",
        help="build a light palette instead of a dark one",
    )
    ap.add_argument(
        "--print", dest="show", action="store_true",
        help="print the palette as swatches instead of writing anything",
    )
    args = ap.parse_args()

    if not os.path.exists(args.image_path):
        print(f"theme_engine: no such image: {args.image_path}", file=sys.stderr)
        return 1

    try:
        clusters = extract_clusters(args.image_path)
    except Exception as exc:
        print(f"theme_engine: {exc}", file=sys.stderr)
        return 1

    p = palette_mod.build(clusters, dark=not args.light)

    if args.show:
        for k, v in sorted(p.items()):
            r, g, b = (int(v[i : i + 2], 16) for i in (1, 3, 5))
            print(f"\x1b[48;2;{r};{g};{b}m      \x1b[0m  {v}  {k}")
        return 0

    written, skipped = [], []
    for label, fn, path, guard in build_targets(
        args.output_dir, args.config_dir, args.home_dir
    ):
        if not _guard_ok(guard):
            skipped.append(label)
            continue
        try:
            fn(p, path)
            written.append(label)
        except OSError as exc:
            print(f"theme_engine: {label}: {exc}", file=sys.stderr)

    msg = f"theme_engine: base {p['base']}, accent {p['accent']} -> {', '.join(written)}"
    if skipped:
        msg += f"  (skipped, not installed: {', '.join(skipped)})"
    print(msg)

    # A program with no target at all produces no line above - it is not
    # "skipped", it simply never appeared. Firefox is the one case where that
    # is expected rather than a bug: profiles are created on first launch, so
    # a machine that has installed Firefox but not yet run it has nothing to
    # write into. Say so, or the omission looks like the theme quietly failing.
    if not firefox_profiles(args.home_dir):
        print(
            "theme_engine: firefox has no profile yet - run it once, then this "
            "will theme it (i3 re-runs theme_init.sh at every login)"
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
