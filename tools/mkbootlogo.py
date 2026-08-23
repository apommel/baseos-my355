#!/usr/bin/env python3
"""Render the my355 boot logo from the BaseOS artwork.

U-Boot draws `logo.bmp` from the resource image inside the boot partition. A
distinct logo is also the only way to tell, on a device with neither a serial
console nor a framebuffer console, whether U-Boot came from the SD card or from
internal NAND — the vendor logo looks identical either way.

The wordmark is cropped out of the 640x480 asset and scaled to the requested
size. Size matters: the resource image is rebuilt around this file, and an
oversized resource hangs U-Boot before display init
(see tools/rkbootimg.py, RESOURCE_SAFE_BYTES).

The asset sits on a near-black gradient. U-Boot draws the logo onto an
otherwise black panel, so that backdrop would show as a lighter rectangle; it is
subtracted so only the wordmark remains.

Usage: mkbootlogo.py ASSET OUT --size WxH [--preview]
"""

from __future__ import annotations

import argparse
import struct
import sys

CONTENT_THRESHOLD = 22        # luminance above the artwork's dark backdrop
BAND_GAP = 20                 # rows of blank that separate one band from another
MARGIN = 8                    # px of clear space kept around the wordmark


def _lum(p):
    return (p[0] * 299 + p[1] * 587 + p[2] * 114) // 1000


def load_bmp(path: str):
    """Return (width, rows, pixels[y][x] as (r,g,b)), normalised to top-down."""
    d = open(path, "rb").read()
    if d[:2] != b"BM":
        sys.exit(f"mkbootlogo: {path} is not a BMP")
    off = struct.unpack("<I", d[10:14])[0]
    w, h = struct.unpack("<ii", d[18:26])
    bpp = struct.unpack("<H", d[28:30])[0]
    if bpp != 24:
        sys.exit(f"mkbootlogo: {path} is {bpp}bpp, expected 24")
    rows = abs(h)
    stride = (w * 3 + 3) & ~3
    out = []
    for y in range(rows):
        yy = (rows - 1 - y) if h > 0 else y
        base = off + yy * stride
        out.append([(d[base + x * 3 + 2], d[base + x * 3 + 1], d[base + x * 3])
                    for x in range(w)])
    return w, rows, out


def find_wordmark(pix, width, rows):
    """Bounding box of the densest lit band.

    A plain threshold box would also capture the faint mark near the artwork's
    bottom edge and return most of the image, so bands are found first and the
    one carrying the most content wins.
    """
    counts = [sum(1 for x in range(width) if _lum(pix[y][x]) > CONTENT_THRESHOLD)
              for y in range(rows)]
    bands, cur = [], None
    for y, c in enumerate(counts):
        if c:
            cur = (y, y) if cur is None else (cur[0], y)
        elif cur and y - cur[1] > BAND_GAP:
            bands.append(cur)
            cur = None
    if cur:
        bands.append(cur)
    if not bands:
        sys.exit("mkbootlogo: no content found in the asset")
    y0, y1 = max(bands, key=lambda b: sum(counts[b[0]:b[1] + 1]))
    xs = [x for y in range(y0, y1 + 1) for x in range(width)
          if _lum(pix[y][x]) > CONTENT_THRESHOLD]
    return min(xs), y0, max(xs), y1


def scale_box(pix, x0, y0, x1, y1, tw, th):
    """Box-filter downscale of a crop to tw x th."""
    sw, sh = x1 - x0 + 1, y1 - y0 + 1
    out = []
    for ty in range(th):
        row = []
        for tx in range(tw):
            ax0, ax1 = x0 + tx * sw // tw, max(x0 + tx * sw // tw + 1, x0 + (tx + 1) * sw // tw)
            ay0, ay1 = y0 + ty * sh // th, max(y0 + ty * sh // th + 1, y0 + (ty + 1) * sh // th)
            r = g = b = n = 0
            for yy in range(ay0, ay1):
                for xx in range(ax0, ax1):
                    p = pix[yy][xx]
                    r += p[0]; g += p[1]; b += p[2]; n += 1
            row.append((r // n, g // n, b // n))
        out.append(row)
    return out


def write_bmp(path: str, width: int, rows: int, px) -> int:
    """Write a bottom-up 24bpp BMP; returns its size."""
    stride = (width * 3 + 3) & ~3
    hdr = bytearray(54)
    hdr[0:2] = b"BM"
    struct.pack_into("<IHHI", hdr, 2, 54 + stride * rows, 0, 0, 54)
    struct.pack_into("<IiiHHIIiiII", hdr, 14, 40, width, rows, 1, 24,
                     0, stride * rows, 2835, 2835, 0, 0)
    body = bytearray()
    for y in range(rows - 1, -1, -1):
        line = bytearray()
        for x in range(width):
            r, g, b = px[y][x]
            line += bytes((b, g, r))
        body += line + b"\0" * (stride - width * 3)
    blob = bytes(hdr) + bytes(body)
    open(path, "wb").write(blob)
    return len(blob)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("asset", help="BaseOS artwork, e.g. assets/bootlogo.bmp")
    ap.add_argument("out")
    ap.add_argument("--size", required=True, metavar="WxH")
    ap.add_argument("--preview", action="store_true",
                    help="ASCII preview; this device costs a reboot to look at a "
                         "logo, so check it here instead")
    a = ap.parse_args()

    width, rows = (int(v) for v in a.size.lower().split("x"))
    aw, ah, apix = load_bmp(a.asset)
    x0, y0, x1, y1 = find_wordmark(apix, aw, ah)
    backdrop = apix[0][0]

    cw, ch = x1 - x0 + 1, y1 - y0 + 1
    sc = min((width - MARGIN) / cw, (rows - MARGIN) / ch)
    tw, th = max(1, int(cw * sc)), max(1, int(ch * sc))
    art = scale_box(apix, x0, y0, x1, y1, tw, th)
    art = [[tuple(max(0, c - b) for c, b in zip(p, backdrop)) for p in row]
           for row in art]

    px = [[(0, 0, 0)] * width for _ in range(rows)]
    ox, oy = (width - tw) // 2, (rows - th) // 2
    for y in range(th):
        for x in range(tw):
            px[oy + y][ox + x] = art[y][x]

    size = write_bmp(a.out, width, rows, px)
    lit = sum(1 for y in range(rows) for x in range(width) if _lum(px[y][x]) > 12)
    print(f"  {a.out}: {width}x{rows} 24bpp, wordmark {cw}x{ch} -> {tw}x{th}, "
          f"{size} bytes, {100 * lit / (width * rows):.0f}% painted")
    if a.preview:
        for y in range(0, rows, max(1, rows // 22)):
            print("  " + "".join("#" if _lum(px[y][x]) > 12 else "."
                                 for x in range(0, width, max(1, width // 70))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
