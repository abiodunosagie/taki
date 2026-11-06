#!/usr/bin/env python3
"""Generates Taki's brand files: the mark, lockups, app icon master and the README banner.

Taki is Japanese for waterfall: many streams falling into one place. The mark is three streams
of different lengths falling into one pool, the way Taki gathers every agent and dev server on
the Mac into one window. The word is Schibsted Grotesk Bold, outlined so no font is needed
(fonts/, SIL Open Font License 1.1).

  python3 brand/generate.py
Needs fontTools (pip install fonttools brotli). Writes into brand/.
"""
import pathlib

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

HERE = pathlib.Path(__file__).resolve().parent
FONT = HERE / "fonts/SchibstedGrotesk-normal-400-800.woff2"

NIGHT = "#080D17"        # icon tile bottom, banner background
DUSK = "#1A2130"         # icon tile top
SPRAY = "#9EDBFF"        # top of the water
DEEP = "#3385FF"         # bottom of the water
INK = "#0F1B33"          # the mark and word on light
PAPER = "#F2F4F7"        # the word on dark, light backgrounds
MIST = "#98A4B8"         # secondary text on Night

# Mark geometry on a 256 grid (the app icon's 824 tile scaled to 256, without the tile).
STREAMS = [(80.8, 44.7, 21.7), (117.1, 29.2, 21.7), (153.5, 51.0, 21.7)]   # (x, top, width)
STREAM_BOTTOM = 184.5                                                          # every stream ends here
POOL = (128, 197, 72.1, 18.6)                                                  # cx, cy, rx, ry


def stream_paths():
    return [f'<rect x="{x}" y="{top}" width="{w}" height="{STREAM_BOTTOM - top}" rx="{w / 2}"/>' for x, top, w in STREAMS]


def pool_path():
    cx, cy, rx, ry = POOL
    return f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}"/>'


def water_gradient(id_):
    return (f'<linearGradient id="{id_}" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{SPRAY}"/><stop offset="1" stop-color="{DEEP}"/></linearGradient>')


def mark(fill, cls=("", "")):
    streams = "".join(stream_paths())
    return f'<g class="{cls[0]}" fill="{fill}">{streams}</g><g class="{cls[1]}" fill="{fill}">{pool_path()}</g>'


def outline(text, weight, size, tracking=0.0):
    """The text as one SVG path at the given size, baseline at y=0. Returns (path, width)."""
    font = instancer.instantiateVariableFont(TTFont(FONT), {"wght": weight})
    glyphs, cmap, upm = font.getGlyphSet(), font.getBestCmap(), font["head"].unitsPerEm
    pen, x, scale = SVGPathPen(glyphs), 0.0, size / upm
    for ch in text:
        name = cmap[ord(ch)]
        glyphs[name].draw(TransformPen(pen, (scale, 0, 0, -scale, x * scale, 0)))
        x += font["hmtx"][name][0] + tracking * upm
    return pen.getCommands(), (x - tracking * upm) * scale


def svg(view_box, body, title="Taki", extra=""):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}"><title>{title}</title>{extra}{body}</svg>\n'


def write(name, content):
    (HERE / name).write_text(content)


def main():
    write("taki-symbol.svg", svg("0 0 256 256", mark("#000")))
    write("taki-symbol-color.svg", svg("0 0 256 256", mark("url(#w)"), extra=f"<defs>{water_gradient('w')}</defs>"))
    write("taki-symbol-reversed.svg", svg("0 0 256 256", f'<rect width="256" height="256" fill="{NIGHT}"/>' + mark("url(#w)"),
                                          extra=f"<defs>{water_gradient('w')}</defs>"))

    # Lockup: the word beside the mark, its baseline level with the pool.
    word, word_width = outline("taki", 700, 150)
    width = 256 + 30 + word_width
    placed = '<path fill="{}" d="' + word + '" transform="translate(286 196)"/>'
    for name, fill, ink, defs in [
        ("taki-lockup.svg", "#000", "#000", ""),
        ("taki-lockup-color.svg", "url(#w)", INK, f"<defs>{water_gradient('w')}</defs>"),
        ("taki-lockup-reversed.svg", "url(#w)", PAPER, f"<defs>{water_gradient('w')}</defs>"),
    ]:
        write(name, svg(f"0 0 {width:.0f} 256", mark(fill) + placed.format(ink), extra=defs))

    # App icon master: the macOS 824 tile on the 1024 grid; the PNGs in the asset catalog match it.
    icon = (
        f'<defs><linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{DUSK}"/><stop offset="1" stop-color="{NIGHT}"/></linearGradient>'
        f'{water_gradient("w")}</defs>'
        f'<rect x="100" y="100" width="824" height="824" rx="185" fill="url(#tile)"/>'
        f'<g transform="translate(100 100) scale(3.21875)">{mark("url(#w)")}</g>'
    )
    write("taki-app-icon.svg", svg("0 0 1024 1024", icon, "Taki app icon"))

    write("banner.svg", banner(animated=True))
    write("banner-static.svg", banner(animated=False))


def banner(animated):
    """1280x640 README header. Animated: the three streams fall one after another, the pool
    spreads where they land, then the word and tagline follow. Reduced motion shows the
    finished frame. Hidden states live only inside the keyframes, so a viewer that ignores CSS
    animation still shows everything."""
    word, _ = outline("taki", 700, 190)
    tagline_1, _ = outline("Every coding agent and dev server", 500, 42)
    tagline_2, _ = outline("on your Mac, in one place.", 500, 42)
    detail, _ = outline("Open source. Swift and SwiftUI. macOS 26 or later.", 400, 26)
    style = ""
    if animated:
        style = """<style>
.s1,.s2,.s3{transform-box:fill-box;transform-origin:top}
.s1{animation:fall .9s cubic-bezier(.55,0,.25,1) .15s both}.s2{animation:fall .9s cubic-bezier(.55,0,.25,1) .35s both}
.s3{animation:fall .9s cubic-bezier(.55,0,.25,1) .55s both}
.pool{transform-box:fill-box;transform-origin:center;animation:spread .9s cubic-bezier(.22,1,.36,1) .95s both}
.word{animation:fade .7s ease-out 1.6s both}.tag{animation:fade .7s ease-out 2s both}.detail{animation:fade .7s ease-out 2.3s both}
@keyframes fall{from{transform:scaleY(0);opacity:.4}}
@keyframes spread{from{transform:scale(.2,.4);opacity:0}}
@keyframes fade{from{opacity:0;transform:translateY(8px)}}
@media (prefers-reduced-motion:reduce){.s1,.s2,.s3,.pool,.word,.tag,.detail{animation:none}}
</style>"""
    streams = "".join(f'<rect class="s{i + 1}" x="{x}" y="{top}" width="{w}" height="{STREAM_BOTTOM - top}" rx="{w / 2}"/>'
                      for i, (x, top, w) in enumerate(STREAMS))
    defs = f"<defs>{water_gradient('w')}</defs>"
    body = (
        f'<rect width="1280" height="640" fill="{NIGHT}"/>{defs}'
        f'<g transform="translate(110 150) scale(1.3)" fill="url(#w)">{streams}<g class="pool">{pool_path()}</g></g>'
        f'<g class="word"><path fill="{PAPER}" d="{word}" transform="translate(500 315)"/></g>'
        f'<g class="tag"><path fill="{PAPER}" d="{tagline_1}" transform="translate(506 392)"/>'
        f'<path fill="{PAPER}" d="{tagline_2}" transform="translate(506 444)"/></g>'
        f'<g class="detail"><path fill="{MIST}" d="{detail}" transform="translate(506 506)"/></g>'
    )
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640" width="1280" height="640">'
            f'<title>Taki</title>{style}{body}</svg>\n')


if __name__ == "__main__":
    main()
