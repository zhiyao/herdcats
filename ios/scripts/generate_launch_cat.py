#!/usr/bin/env python3

import struct
import zlib
from pathlib import Path


POINTS_PER_UNIT = 2
ASSET_SCALES = {
    2: "LaunchCat@2x.png",
    3: "LaunchCat@3x.png",
}
BLOCKS = [
    (-13, -7, 2, 7, (199, 163, 122, 255)),
    (-15, -8, 4, 2, (199, 163, 122, 255)),
    (-11, -2, 15, 6, (199, 163, 122, 255)),
    (1, -6, 7, 8, (199, 163, 122, 255)),
    (1, -9, 2, 4, (199, 163, 122, 255)),
    (6, -9, 2, 4, (199, 163, 122, 255)),
    (-9, 3, 3, 4, (199, 163, 122, 255)),
    (1, 3, 3, 4, (199, 163, 122, 255)),
    (5, -4, 1, 2, (40, 33, 24, 255)),
    (7, 0, 2, 1, (217, 135, 125, 255)),
]


def png_chunk(chunk_type, data):
    payload = chunk_type + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))


def render(scale):
    min_x = min(x for x, _, _, _, _ in BLOCKS)
    min_y = min(y for _, y, _, _, _ in BLOCKS)
    max_x = max(x + width for x, _, width, _, _ in BLOCKS)
    max_y = max(y + height for _, y, _, height, _ in BLOCKS)
    pixels_per_unit = POINTS_PER_UNIT * scale
    width = (max_x - min_x) * pixels_per_unit
    height = (max_y - min_y) * pixels_per_unit
    pixels = bytearray(width * height * 4)

    for x, y, block_width, block_height, color in BLOCKS:
        left = (x - min_x) * pixels_per_unit
        top = (y - min_y) * pixels_per_unit
        right = left + block_width * pixels_per_unit
        bottom = top + block_height * pixels_per_unit
        for pixel_y in range(top, bottom):
            for pixel_x in range(left, right):
                offset = (pixel_y * width + pixel_x) * 4
                pixels[offset:offset + 4] = bytes(color)

    scanlines = b"".join(
        b"\x00" + pixels[row * width * 4:(row + 1) * width * 4]
        for row in range(height)
    )
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(scanlines))
        + png_chunk(b"IEND", b"")
    )


def main():
    output_directory = (
        Path(__file__).resolve().parents[1]
        / "Herdcats/Assets.xcassets/LaunchCat.imageset"
    )
    for scale, filename in ASSET_SCALES.items():
        output = output_directory / filename
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(render(scale))


if __name__ == "__main__":
    main()
