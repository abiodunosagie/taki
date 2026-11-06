# Taki brand

## The idea

Taki is Japanese for waterfall: many streams falling into one place. The mark is three streams of different lengths falling into one pool, the way Taki gathers every agent and dev server on the Mac into one window.

- **Mark**: the app icon and anywhere square.
- **Lockup**: the mark beside the word `taki`, for the README, the banner and anywhere wide. The word's baseline sits level with the pool.

## Colour

| Name | HEX | Use |
|---|---|---|
| Night | `#080D17` | icon tile bottom, banner background |
| Dusk | `#1A2130` | icon tile top |
| Spray | `#9EDBFF` | top of the water gradient |
| Deep | `#3385FF` | bottom of the water gradient, links |
| Ink | `#0F1B33` | the word on light backgrounds |
| Paper | `#F2F4F7` | the word on Night, light backgrounds |
| Mist | `#98A4B8` | secondary text on Night |

## Type

Schibsted Grotesk: Bold for the word, Medium and Regular for the banner text. All text in the brand files is outlined, so no font is needed to show them. The font is SIL Open Font License 1.1 (`fonts/OFL.txt`).

## Files

| File | Use |
|---|---|
| `taki-symbol.svg`, `-color.svg`, `-reversed.svg` | the mark in black, in colour, and on Night |
| `taki-lockup.svg`, `-color.svg`, `-reversed.svg` | mark and word, same three versions |
| `taki-app-icon.svg` | app icon master (824 tile on the 1024 grid); the PNGs in `Taki/Resources/Assets.xcassets` match it |
| `banner.svg` | animated README header: the three streams fall one after another, the pool spreads where they land, the word follows. Still under reduced motion. |
| `banner-static.svg`, `banner.png` | still banner; the PNG (1280x640) is the GitHub social preview |
| `generate.py` | regenerates every SVG above (`python3 brand/generate.py`, needs fontTools) |

## Use

- Clear space: at least one stream's width around the mark, twice that around the lockup.
- Keep the water gradient running top to bottom, light to deep. Don't recolour the streams one by one.
