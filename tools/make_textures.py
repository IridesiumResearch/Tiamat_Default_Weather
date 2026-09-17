# SPDX-License-Identifier: MIT
"""Generates the textures for mods/tiamot_weather/textures.

One flat colour per block, the Spindle's convention: variation across a
surface is the renderer's (the block's tint), never baked into the picture.
The damp blocks are their dry block's colour from the Spindle's own
generator, darkened. No dependencies beyond the standard library; run from
the repository root:

    python tools/make_textures.py
"""
import struct
import zlib
from pathlib import Path

SIZE = 16
OUT = Path(__file__).resolve().parent.parent / "mods" / "tiamot_weather" / "textures"

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
}
for name, (r, g, b) in DRY.items():
    COLOURS["damp_" + name] = (int(r * WET), int(g * WET), int(b * WET))


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


if __name__ == "__main__":
    main()
