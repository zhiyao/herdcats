#!/usr/bin/env python3
"""Render the single-cat logo on the Moonlit night canvas for every surface."""

import importlib.util
import struct
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("launch_cat", HERE / "generate_launch_cat.py")
launch_cat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch_cat)

CANVAS = (0x1B, 0x28, 0x2E)  # Palette.night950
# (output, canvas size, pixels per cat cell); whole cells keep the edges crisp.
OUTPUTS = [
    ("ios/Herdcats/Assets.xcassets/AppIcon.appiconset/AppIcon.png", 1024, 26),
    ("ios/Herdcats/Assets.xcassets/HerdrcatLogo.imageset/HerdrcatLogo.png", 1024, 26),
    ("web/public/assets/logo.png", 512, 14),
    ("web/public/assets/apple-touch-icon.png", 180, 5),
    ("web/public/assets/favicon.png", 32, 1),
]


def render(size, cell):
    blocks = launch_cat.BLOCKS
    min_x = min(x for x, _, _, _, _ in blocks)
    min_y = min(y for _, y, _, _, _ in blocks)
    cols = max(x + w for x, _, w, _, _ in blocks) - min_x
    rows = max(y + h for _, y, _, h, _ in blocks) - min_y
    offset_x = (size - cols * cell) // 2
    offset_y = (size - rows * cell) // 2
    pixels = bytearray(bytes(CANVAS) * size * size)
    for x, y, w, h, color in blocks:
        left = offset_x + (x - min_x) * cell
        top = offset_y + (y - min_y) * cell
        for row in range(top, top + h * cell):
            start = (row * size + left) * 3
            pixels[start:start + w * cell * 3] = bytes(color[:3]) * (w * cell)
    scanlines = b"".join(
        b"\x00" + pixels[row * size * 3:(row + 1) * size * 3] for row in range(size)
    )
    chunk = launch_cat.png_chunk
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(scanlines))
        + chunk(b"IEND", b"")
    )


def main():
    for relative, size, cell in OUTPUTS:
        (REPO / relative).write_bytes(render(size, cell))


if __name__ == "__main__":
    main()
