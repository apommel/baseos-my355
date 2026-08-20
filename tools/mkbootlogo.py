#!/usr/bin/env python3
"""Render a my355 boot logo by repainting the vendor BMP's pixel data.

The Flip's U-Boot draws `logo.bmp` from the resource image inside the boot
partition. Replacing it is how you tell, on a device with no serial console and
no framebuffer console, *which* boot chain actually ran — the vendor logo looks
identical whether U-Boot came from NAND or from the card.

The vendor BMP's 138-byte header (BITMAPV5) is reused verbatim and only the
pixel block is repainted, so the file stays byte-for-byte the same size and
U-Boot's parser sees exactly the structure it already accepts. That is required:
tools/rkbootimg.py only repacks in place.

Usage: mkbootlogo_my355.py VENDOR_BMP OUT_BMP [--text BASEOS] [--rgb R,G,B]
"""

from __future__ import annotations

import argparse
import struct
import sys

FONT = {
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    " ": ("00000",) * 7,
}


def render(width: int, height: int, text: str, fg, bg, scale: int):
    """Return a [y][x] -> (r,g,b) buffer with `text` centred."""
    px = [[bg for _ in range(width)] for _ in range(height)]
    glyphs = [FONT.get(c, FONT[" "]) for c in text]
    gw, gh = 5 * scale, 7 * scale
    total = len(glyphs) * (gw + scale) - scale
    x0 = (width - total) // 2
    y0 = (height - gh) // 2
    for gi, g in enumerate(glyphs):
        gx = x0 + gi * (gw + scale)
        for row in range(7):
            for col in range(5):
                if g[row][col] != "1":
                    continue
                for dy in range(scale):
                    for dx in range(scale):
                        x, y = gx + col * scale + dx, y0 + row * scale + dy
                        if 0 <= x < width and 0 <= y < height:
                            px[y][x] = fg
    # a border, so a partially drawn logo is still obviously ours
    for x in range(width):
        for y in (0, 1, height - 2, height - 1):
            px[y][x] = fg
    for y in range(height):
        for x in (0, 1, width - 2, width - 1):
            px[y][x] = fg
    return px


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("vendor_bmp")
    ap.add_argument("out_bmp")
    ap.add_argument("--text", default="BASEOS")
    ap.add_argument("--rgb", default="0,200,255", help="foreground R,G,B")
    ap.add_argument("--bg", default="0,0,0")
    a = ap.parse_args()

    src = open(a.vendor_bmp, "rb").read()
    if src[:2] != b"BM":
        sys.exit("mkbootlogo_my355: not a BMP")
    data_off = struct.unpack("<I", src[10:14])[0]
    width, height = struct.unpack("<ii", src[18:26])
    bpp = struct.unpack("<H", src[28:30])[0]
    if bpp != 24:
        sys.exit(f"mkbootlogo_my355: expected 24bpp, got {bpp}")

    fg = tuple(int(v) for v in a.rgb.split(","))
    bg = tuple(int(v) for v in a.bg.split(","))
    scale = max(1, min((width - 8) // (6 * len(a.text)), (height - 8) // 9))
    px = render(width, abs(height), a.text, fg, bg, scale)

    row_bytes = width * 3
    stride = (row_bytes + 3) & ~3
    body = bytearray()
    rows = range(abs(height) - 1, -1, -1) if height > 0 else range(abs(height))
    for y in rows:                       # BMP rows are bottom-up when height > 0
        line = bytearray()
        for x in range(width):
            r, g, b = px[y][x]
            line += bytes((b, g, r))
        line += b"\0" * (stride - row_bytes)
        body += line

    out = bytearray(src)
    if data_off + len(body) != len(src):
        sys.exit(f"mkbootlogo_my355: repaint size mismatch "
                 f"({data_off}+{len(body)} != {len(src)}); refusing")
    out[data_off:] = body
    open(a.out_bmp, "wb").write(bytes(out))
    print(f"  {a.out_bmp}: {width}x{abs(height)} {bpp}bpp, "
          f"'{a.text}' scale {scale}, {len(out)} bytes (vendor: {len(src)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
