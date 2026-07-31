"""
Palette construction.

The job here is to turn "some colours that happen to be in a wallpaper" into
"a palette you can actually read text on". Those are very different things: a
photo of a sunset is mostly low-contrast orange, and a naive dominant-colour
extraction gives you orange text on an orange bar.

So the wallpaper decides *hue and mood*, and this module decides *lightness and
contrast*. Every foreground colour is pushed until it hits a WCAG contrast
ratio against the background it will actually be drawn on, which is what keeps
the desktop legible no matter what image you throw at it.
"""

import colorsys

# --- contrast targets -------------------------------------------------------
# WCAG 2.1 ratios. 7.0 is AAA body text, 4.5 is AA body text, 3.0 is AA large
# text / UI chrome. Borders and inactive elements get 3.0 because they are
# shapes, not words.
CONTRAST_TEXT = 7.0
CONTRAST_SUBTEXT = 4.5
CONTRAST_ACCENT = 4.5
CONTRAST_CHROME = 3.0


# ============================================================================
# colour space helpers
#
# Everything internally is (h, l, s) floats in 0..1, because lightness is the
# knob we need to turn and HLS is the only common space where it is one axis.
# ============================================================================


def hex_to_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i : i + 2], 16) / 255.0 for i in (0, 2, 4))


def rgb_to_hex(rgb):
    return "#{:02x}{:02x}{:02x}".format(
        *[max(0, min(255, round(c * 255))) for c in rgb]
    )


def rgb_to_hls(rgb):
    return colorsys.rgb_to_hls(*rgb)


def hls_to_rgb(hls):
    return colorsys.hls_to_rgb(*hls)


def hls_to_hex(hls):
    return rgb_to_hex(hls_to_rgb(hls))


def hex_to_hls(h):
    return rgb_to_hls(hex_to_rgb(h))


def clamp(x, lo=0.0, hi=1.0):
    return max(lo, min(hi, x))


# ============================================================================
# contrast
# ============================================================================


def relative_luminance(rgb):
    """WCAG relative luminance of a linear-ised sRGB triple."""

    def channel(c):
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

    r, g, b = (channel(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(rgb_a, rgb_b):
    la, lb = relative_luminance(rgb_a), relative_luminance(rgb_b)
    lo, hi = sorted((la, lb))
    return (hi + 0.05) / (lo + 0.05)


def quantize(hls):
    """Round-trip through 8-bit hex.

    Contrast has to be measured on the value that actually lands in the config
    file, not on the float behind it - rounding #f8a562 costs a few hundredths
    of a ratio, which is exactly enough to drop a colour just under its target.
    """
    return hex_to_rgb(hls_to_hex(hls))


def ensure_contrast(hls, bg_hls, target):
    """Walk `hls` away from `bg_hls` in lightness until it clears `target`.

    Hue is never touched and saturation only sags at the very extremes, so the
    colour keeps its identity - a wallpaper-derived red stays red, it just
    stops being unreadable.
    """
    bg_rgb = quantize(bg_hls)
    h, l, s = hls

    # Move away from the background: lighter on a dark bg, darker on a light one.
    direction = 1.0 if bg_hls[1] < 0.5 else -1.0

    for _ in range(100):
        if contrast_ratio(quantize((h, l, s)), bg_rgb) >= target:
            return (h, l, s)
        l = clamp(l + direction * 0.01)
        if l in (0.0, 1.0):
            break

    # Pinned at pure white/black and still short: the only thing left to give is
    # saturation, which is what was eating the luminance.
    for _ in range(100):
        if contrast_ratio(quantize((h, l, s)), bg_rgb) >= target:
            break
        s = clamp(s - 0.02)
        if s == 0.0:
            break
    return (h, l, s)


def mix(hls_a, hls_b, t):
    """Blend two colours in RGB (linear enough for UI surfaces)."""
    ra, rb = hls_to_rgb(hls_a), hls_to_rgb(hls_b)
    return rgb_to_hls(tuple(a + (b - a) * t for a, b in zip(ra, rb)))


# ============================================================================
# the palette
# ============================================================================

# Canonical hues for the 16 ANSI slots, in degrees. A terminal red has to look
# like a red - `git diff` and every TUI on the system depend on it - so these
# are anchors that the wallpaper is only allowed to nudge, never replace.
ANSI_HUES = {
    "red": 0,
    "green": 130,
    "yellow": 45,
    "blue": 215,
    "magenta": 300,
    "cyan": 180,
}

# How far, in degrees, a wallpaper may pull an ANSI hue toward its own dominant
# hue. Enough to feel like it belongs to the image, not enough to turn the
# green slot teal.
HUE_PULL = 12


def _pull_hue(base_deg, toward_deg, amount=HUE_PULL):
    """Nudge base_deg toward toward_deg by at most `amount`, the short way."""
    delta = ((toward_deg - base_deg + 180) % 360) - 180
    return (base_deg + max(-amount, min(amount, delta))) % 360


def build(clusters, dark=True):
    """Build the full palette from KMeans cluster centres.

    `clusters` is a list of (rgb_float_triple, weight) sorted by weight
    descending. Returns a flat dict of name -> "#rrggbb".
    """
    hls_clusters = [(rgb_to_hls(rgb), w) for rgb, w in clusters]

    # --- pick the two colours the wallpaper actually votes for ---------------
    # Background hue: the heaviest cluster. It is the wall, the sky, the thing
    # the image is mostly made of.
    bg_seed = hls_clusters[0][0]

    # Accent hue: the most colourful cluster, weighted a little by how much of
    # the image it covers so a stray 40-pixel highlight does not win.
    accent_seed = max(hls_clusters, key=lambda c: c[0][2] * (0.35 + c[1]))[0]

    dominant_hue = accent_seed[0] * 360.0
    # A greyscale wallpaper has no opinion about saturation; give the UI a
    # floor so it does not come out completely flat.
    image_sat = clamp(max(c[0][2] for c in hls_clusters), 0.25, 0.85)

    p = {}

    if dark:
        # --- surfaces --------------------------------------------------------
        # The background keeps the wallpaper's hue but is forced down to a
        # lightness that can carry text, with just enough saturation to read as
        # tinted rather than grey.
        base = (bg_seed[0], 0.085, clamp(bg_seed[2], 0.10, 0.35))
        crust = (base[0], 0.045, base[2])
        mantle = (base[0], 0.065, base[2])
        # Surfaces step up in lightness. These are bar segments, selected rows,
        # inactive borders - they must be distinguishable from base at a glance
        # but must not compete with text.
        surface0 = (base[0], 0.145, base[2] * 0.95)
        surface1 = (base[0], 0.205, base[2] * 0.90)
        surface2 = (base[0], 0.265, base[2] * 0.85)
        overlay0 = (base[0], 0.36, base[2] * 0.75)
        overlay1 = (base[0], 0.45, base[2] * 0.70)

        # --- text ------------------------------------------------------------
        # Desaturated toward white so long-form text stays comfortable, then
        # pushed until it clears AAA against base.
        text = ensure_contrast((base[0], 0.90, 0.12), base, CONTRAST_TEXT)
        subtext = ensure_contrast((base[0], 0.72, 0.10), base, CONTRAST_SUBTEXT)
        muted = ensure_contrast((base[0], 0.58, 0.09), base, CONTRAST_CHROME)

        # --- accent ----------------------------------------------------------
        # This is the colour the whole desktop is keyed on: focused window
        # border, active workspace, rofi selection, cursor, git branch.
        accent = ensure_contrast(
            (accent_seed[0], 0.68, clamp(accent_seed[2] * 1.35, 0.45, 0.92)),
            base,
            CONTRAST_ACCENT,
        )
        accent_dim = mix(accent, base, 0.55)
    else:
        base = (bg_seed[0], 0.94, clamp(bg_seed[2], 0.05, 0.20))
        crust = (base[0], 0.99, base[2])
        mantle = (base[0], 0.965, base[2])
        surface0 = (base[0], 0.88, base[2])
        surface1 = (base[0], 0.82, base[2])
        surface2 = (base[0], 0.76, base[2])
        overlay0 = (base[0], 0.62, base[2])
        overlay1 = (base[0], 0.52, base[2])
        text = ensure_contrast((base[0], 0.14, 0.20), base, CONTRAST_TEXT)
        subtext = ensure_contrast((base[0], 0.30, 0.18), base, CONTRAST_SUBTEXT)
        muted = ensure_contrast((base[0], 0.45, 0.15), base, CONTRAST_CHROME)
        accent = ensure_contrast(
            (accent_seed[0], 0.40, clamp(accent_seed[2] * 1.2, 0.45, 0.90)),
            base,
            CONTRAST_ACCENT,
        )
        accent_dim = mix(accent, base, 0.55)

    for name, v in [
        ("crust", crust),
        ("mantle", mantle),
        ("base", base),
        ("surface0", surface0),
        ("surface1", surface1),
        ("surface2", surface2),
        ("overlay0", overlay0),
        ("overlay1", overlay1),
        ("text", text),
        ("subtext", subtext),
        ("muted", muted),
        ("accent", accent),
        ("accent_dim", accent_dim),
    ]:
        p[name] = hls_to_hex(v)

    # --- the 16 ANSI slots ---------------------------------------------------
    # Normal variants are contrast-checked against base so terminal output is
    # readable; bright variants are the same hue lifted, and are only held to
    # the AA large-text bar because they are used for emphasis, not paragraphs.
    normal_l = 0.62 if dark else 0.42
    bright_l = 0.74 if dark else 0.52
    for name, hue in ANSI_HUES.items():
        h = _pull_hue(hue, dominant_hue) / 360.0
        s = clamp(image_sat * 1.15, 0.45, 0.85)
        p[name] = hls_to_hex(ensure_contrast((h, normal_l, s), base, CONTRAST_ACCENT))
        p["bright_" + name] = hls_to_hex(
            ensure_contrast((h, bright_l, clamp(s * 0.92, 0.35, 0.80)), base, CONTRAST_CHROME)
        )

    # black/white round out the 16. "black" is a visible dark grey, not #000000,
    # because programs use colour0 for dim text and true black would vanish.
    p["black"] = p["surface1"]
    p["bright_black"] = p["overlay0"]
    p["white"] = p["subtext"]
    p["bright_white"] = p["text"]

    # --- semantic aliases ----------------------------------------------------
    # Everything downstream should reach for these, so the meaning of a colour
    # lives here rather than being re-decided in each config file.
    p["urgent"] = p["red"]
    p["warning"] = p["yellow"]
    p["success"] = p["green"]
    p["info"] = p["blue"]
    p["selection"] = p["surface1"]
    p["border_active"] = p["accent"]
    p["border_inactive"] = p["surface1"]
    p["cursor"] = p["accent"]

    # --- polybar's historical names ------------------------------------------
    # bars.ini / modules.ini / user_modules.ini reference these directly, and
    # rewriting 100+ references buys nothing. shade1..8 is a light ramp.
    p["background"] = p["base"]
    p["foreground"] = p["text"]
    p["foreground-alt"] = p["muted"]
    ramp = [surface0, surface1, surface2, overlay0, overlay1]
    for i in range(1, 9):
        # 1..5 walk the surface ramp, 6..8 lean on the accent so the bar's
        # busier modules pick up the desktop's key colour.
        if i <= 5:
            p[f"shade{i}"] = hls_to_hex(ramp[i - 1])
        else:
            p[f"shade{i}"] = hls_to_hex(mix(overlay1, accent, (i - 5) / 3.5))

    return p
