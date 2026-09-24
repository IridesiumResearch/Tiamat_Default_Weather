# SPDX-FileCopyrightText: Iridesium
# SPDX-License-Identifier: GPL-3.0-only
"""Generates the textures for mods/tiamat_weather/textures.

One flat colour per block, the Spindle's convention: variation across a
surface is the renderer's (the block's tint), never baked into the picture.
The damp blocks are their dry block's colour from the Spindle's own
generator, darkened; what a fire leaves behind is flat too. No dependencies
beyond the standard library; run from the repository root:

    python tools/make_textures.py

The one exception is `fire.png`, which is a SHAPE rather than a colour. A
fire block is a billboard sprite, and a sprite's alpha is its silhouette:
the client alpha-tests it at a half, as it does the Spindle's grass, so the
alpha is binary and the picture is a flame. It is drawn from a description
(three nested tongues and two flickers) with integer and float `+ - * /`
only, so the bytes come out the same on every machine that runs this.
"""
import struct
import zlib
from pathlib import Path

SIZE = 16
OUT = Path(__file__).resolve().parent.parent / "mods" / "tiamat_weather" / "textures"

# The Spindle's dry colours (tools/make_textures.py there), and how much of
# each channel is kept when it is wet.
DRY = {
    "dirt": (98, 78, 58),
    "packed_dirt": (124, 102, 72),
    "sand": (194, 180, 138),
}
WET = 0.68

COLOURS = {
    "snow_layer": (238, 242, 248),
    "rainwater": (150, 175, 195, 150),
    # What a fire leaves: a trunk gone to charcoal, and turf it went over.
    "charred_log": (28, 24, 22),
    "scorched_ground": (52, 44, 38),
}
for name, (r, g, b) in DRY.items():
    COLOURS["damp_" + name] = (int(r * WET), int(g * WET), int(b * WET))

# The flame, outside in: the tongue's edge, its body, and the heart at the
# centre of the base where it is hottest.
FLAME = (236, 88, 20)
GLOW = (250, 160, 30)
CORE = (255, 236, 150)


def lcg(seed):
    """A stream of fractions in [0, 1), the same on every machine: the
    edge jitter must not depend on the platform's random module."""
    state = seed & 0xFFFFFFFF
    while True:
        state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
        yield state / 4294967296.0


def tongue(px, row, base_x, base_row, half, height, lean, jitter=(0.0, 0.0)):
    """Whether the pixel whose centre is `px` on `row` is inside a tongue of
    flame standing on `base_row`, `half` pixels either side of `base_x` at its
    foot, `height` rows tall and leaning `lean` pixels by its tip.

    The width closes from the foot to a point along a curve that bulges rather
    than a straight taper, which is what a candle flame does; the lean grows
    with the square of the height so the foot stays planted and only the tip
    bends, as a flame in a draught does. `jitter` nudges the two edges."""
    h = base_row - row
    if h < 0 or h >= height:
        return False
    u = h / height
    width = half * (1.0 - u) * (1.0 + 0.6 * u)
    centre = base_x + lean * u * u
    return centre - width + jitter[0] <= px <= centre + width + jitter[1]


def flame():
    """The fire sprite: a wide tongue rising from the bottom edge to a point
    near the top, orange-red at its edge, orange within and yellow-white at
    the heart, with two small licks breaking off either side. Transparent
    everywhere else — a sprite alpha-tests, so alpha is 0 or 255 and nothing
    in between."""
    rows = []
    edge = lcg(0xF1A3E)
    # The outer edge flickers a little from row to row so the silhouette is a
    # flame and not a cone; the body and the heart inside it stay smooth.
    wobble = [((next(edge) - 0.5) * 0.7, (next(edge) - 0.5) * 0.7) for _ in range(SIZE)]
    for row in range(SIZE):
        line = []
        for x in range(SIZE):
            px = x + 0.5
            if tongue(px, row, 8.0, 15, 2.0, 6.0, 0.3):
                colour = CORE
            elif tongue(px, row, 8.0, 15, 3.5, 10.5, 0.6):
                colour = GLOW
            elif tongue(px, row, 8.0, 15, 5.0, 14.5, 0.8, wobble[row]):
                colour = FLAME
            elif tongue(px, row, 1.6, 10, 0.9, 4.5, -0.4) or tongue(px, row, 14.2, 9, 0.9, 4.0, 0.5):
                colour = FLAME                       # the two side flickers
            else:
                colour = None
            line.extend((*colour, 255) if colour else (0, 0, 0, 0))
        rows.append(line)
    return rows


SHAPES = {
    "fire": flame,
}


def png(width, height, rows):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for name, colour in COLOURS.items():
        r, g, b = colour[:3]
        a = colour[3] if len(colour) > 3 else 255
        rows = [[r, g, b, a] * SIZE for _ in range(SIZE)]
        (OUT / f"{name}.png").write_bytes(png(SIZE, SIZE, rows))
        print("wrote", name)
    for name, draw in SHAPES.items():
        (OUT / f"{name}.png").write_bytes(png(SIZE, SIZE, draw()))
        print("wrote", name)


if __name__ == "__main__":
    main()
