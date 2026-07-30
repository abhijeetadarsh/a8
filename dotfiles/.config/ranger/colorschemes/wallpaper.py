"""
ranger colourscheme built only out of the 16 ANSI slots.

ranger cannot take hex colours, so it cannot read the generated palette
directly. It does not need to: kitty's 16 ANSI colours are regenerated from the
wallpaper on every theme_init.sh run, and this scheme is written entirely in
terms of those slots. Change the wallpaper and ranger follows, with no
generated file of its own.

Anything that hardcodes a colour here would be the one thing on the desktop
that does not follow the theme, so nothing does.
"""

from ranger.gui.color import (
    black,
    blue,
    bold,
    cyan,
    default,
    default_colors,
    green,
    magenta,
    normal,
    red,
    reverse,
    yellow,
)
from ranger.gui.colorscheme import ColorScheme


class Wallpaper(ColorScheme):
    progress_bar_color = blue

    def use(self, context):  # noqa: C901 - one flat table, ranger's own shape
        fg, bg, attr = default_colors

        if context.reset:
            return default_colors

        if context.in_browser:
            if context.selected:
                attr = reverse
            else:
                attr = normal

            if context.empty or context.error:
                fg = red
            if context.border:
                fg = default
            if context.media:
                fg = magenta if context.image else yellow
            if context.container:
                fg = red
            if context.directory:
                attr |= bold
                fg = blue
            elif context.executable and not any(
                (context.media, context.container, context.fifo, context.socket)
            ):
                attr |= bold
                fg = green
            if context.socket:
                attr |= bold
                fg = magenta
            if context.fifo or context.device:
                fg = yellow
                if context.device:
                    attr |= bold
            if context.link:
                fg = cyan if context.good else red
            if context.tag_marker and not context.selected:
                attr |= bold
                fg = red if fg in (red, magenta) else yellow
            if not context.selected and (context.cut or context.copied):
                attr |= bold
                fg = black
            if context.main_column:
                if context.selected:
                    attr |= bold
                if context.marked:
                    attr |= bold | reverse
                    fg = yellow
            if context.badinfo:
                if attr & reverse:
                    bg = magenta
                else:
                    fg = magenta
            if context.inactive_pane:
                fg = cyan

        elif context.in_titlebar:
            attr |= bold
            if context.hostname:
                fg = red if context.bad else green
            elif context.directory:
                fg = blue
            elif context.tab:
                if context.good:
                    bg = green
            elif context.link:
                fg = cyan

        elif context.in_statusbar:
            if context.permissions:
                if context.good:
                    fg = cyan
                elif context.bad:
                    fg = magenta
            if context.marked:
                attr |= bold | reverse
                fg = yellow
            if context.frozen:
                attr |= bold | reverse
                fg = cyan
            if context.message:
                if context.bad:
                    attr |= bold
                    fg = red
            if context.loaded:
                bg = self.progress_bar_color
            if context.vcsinfo:
                fg = blue
                attr &= ~bold
            elif context.vcscommit:
                fg = yellow
                attr &= ~bold
            elif context.vcsdate:
                fg = cyan
                attr &= ~bold

        if context.text:
            if context.highlight:
                attr |= reverse

        if context.in_taskview:
            if context.title:
                fg = blue
            if context.selected:
                attr |= reverse
            if context.loaded:
                if context.selected:
                    fg = self.progress_bar_color
                else:
                    bg = self.progress_bar_color

        if context.vcsfile and not context.selected:
            attr &= ~bold
            if context.vcsconflict:
                fg = magenta
            elif context.vcsuntracked:
                fg = cyan
            elif context.vcschanged:
                fg = red
            elif context.vcsunknown:
                fg = red
            elif context.vcsstaged:
                fg = green
            elif context.vcssync:
                fg = green
            elif context.vcsignored:
                fg = default

        elif context.vcsremote and not context.selected:
            attr &= ~bold
            if context.vcssync or context.vcsnone:
                fg = green
            elif context.vcsbehind:
                fg = red
            elif context.vcsahead:
                fg = blue
            elif context.vcsdiverged:
                fg = magenta
            elif context.vcsunknown:
                fg = red

        return fg, bg, attr
