#!/usr/bin/env python3
"""Rockchip Android boot image surgery for the my355 (Miyoo Flip) port.

The Flip's vendor kernel ships as an Android boot image in `mtd2`:

    ANDROID! header (2 KiB page)
      kernel      raw arm64 Image, page-aligned
      ramdisk     empty on this device — the kernel mounts root directly
      second      a Rockchip resource image ("RSCE") holding rk-kernel.dtb
                  plus the U-Boot logos and battery bitmaps

The kernel command line is *not* in the boot header (that field is empty).
It lives in `/chosen/bootargs` inside rk-kernel.dtb, inside the resource image:

    earlycon=... console=ttyFIQ0 root=/dev/mtdblock3 rootfstype=squashfs rootwait

Booting the vendor kernel from SD therefore needs exactly one string changed.
This tool rewrites it in place and repacks, so the kernel Image and every other
resource entry stay byte-for-byte vendor — the same doctrine the H700 port
applies to its boot chain (docs/00).

The device tree is patched without relayout — the replacement bootargs is padded
with spaces to the original length, so the FDT keeps its size and no offsets
move. That caps how long the new command line can be; `info` reports the budget.

The resource image around it is rebuilt rather than patched, which frees the
logo from having to match the vendor's exact byte count and lets the whole
resource stay small enough for U-Boot's loader (see RESOURCE_SAFE_BYTES).

Usage:
    rkbootimg.py info    BOOTIMG
    rkbootimg.py extract BOOTIMG OUTDIR
    rkbootimg.py setargs BOOTIMG OUT --root /dev/mmcblk1p4 --rootfstype ext4
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys

PAGE_DEFAULT = 2048
# Largest resource image observed to boot on hardware. 943 616 bytes hangs this
# U-Boot before display init; 465 408 boots. The exact threshold is unmeasured.
RESOURCE_SAFE_BYTES = 465408
RES_MAGIC = b"RSCE"
RES_BLOCK = 512
RES_NAME_LEN = 256
FDT_MAGIC = b"\xd0\x0d\xfe\xed"


def _pad(value: int, page: int) -> int:
    return ((value + page - 1) // page) * page


class BootImage:
    """An `ANDROID!` boot image, split into its three payloads."""

    def __init__(self, blob: bytes) -> None:
        if blob[:8] != b"ANDROID!":
            raise ValueError("not an Android boot image")
        self.blob = blob
        (self.kernel_size, self.kernel_addr, self.ramdisk_size, self.ramdisk_addr,
         self.second_size, self.second_addr, self.tags_addr,
         self.page_size) = struct.unpack("<8I", blob[8:40])
        page = self.page_size
        self.kernel_off = page
        self.ramdisk_off = self.kernel_off + _pad(self.kernel_size, page)
        self.second_off = self.ramdisk_off + _pad(self.ramdisk_size, page)

    @property
    def kernel(self) -> bytes:
        return self.blob[self.kernel_off:self.kernel_off + self.kernel_size]

    @property
    def second(self) -> bytes:
        return self.blob[self.second_off:self.second_off + self.second_size]

    @property
    def ramdisk(self) -> bytes:
        return self.blob[self.ramdisk_off:self.ramdisk_off + self.ramdisk_size]

    def compute_id(self, blob: bytes | None = None) -> bytes:
        """SHA1 over kernel|size|ramdisk|size|second|size, as mkbootimg defines it.

        U-Boot verifies this before booting ("ANDROID: Hash OK"). Editing any
        payload without refreshing it makes boot_android refuse the image —
        while the *resource* image is still read earlier and unverified, so a
        replaced logo appears and then nothing boots.
        """
        src = blob if blob is not None else self.blob
        page = self.page_size
        ko = page
        ro = ko + _pad(self.kernel_size, page)
        so = ro + _pad(self.ramdisk_size, page)
        parts = ((src[ko:ko + self.kernel_size], self.kernel_size),
                 (src[ro:ro + self.ramdisk_size], self.ramdisk_size),
                 (src[so:so + self.second_size], self.second_size))
        h = hashlib.sha1()
        for payload, size in parts:
            h.update(payload)
            h.update(struct.pack("<I", size))
        return h.digest()

    @property
    def stored_id(self) -> bytes:
        return self.blob[576:576 + 20]

    def rebuild(self, second: bytes) -> bytes:
        """Repack with a differently sized `second`, refreshing sizes and the id."""
        page = self.page_size
        b = bytearray(self.blob[:page])                       # header page
        struct.pack_into("<I", b, 8 + 16, len(second))        # second_size field
        out = bytearray(b)
        out += self.kernel + b"\0" * (_pad(self.kernel_size, page) - self.kernel_size)
        out += self.ramdisk + b"\0" * (_pad(self.ramdisk_size, page) - self.ramdisk_size)
        out += second + b"\0" * (_pad(len(second), page) - len(second))
        rebuilt = BootImage(bytes(out))
        digest = rebuilt.compute_id()
        out[576:576 + 20] = digest
        out[576 + 20:576 + 32] = b"\0" * 12
        return bytes(out)



class ResourceImage:
    """A Rockchip `RSCE` resource image: a flat table of named blobs."""

    def __init__(self, blob: bytes) -> None:
        if blob[:4] != RES_MAGIC:
            raise ValueError("not a Rockchip resource image")
        self.blob = blob
        self.header_blocks = blob[8]
        self.entry_blocks = blob[9]
        self.count = struct.unpack("<I", blob[12:16])[0]

    def entries(self):
        for i in range(self.count):
            base = self.header_blocks * RES_BLOCK + i * self.entry_blocks * RES_BLOCK
            ent = self.blob[base:base + self.entry_blocks * RES_BLOCK]
            name = ent[4:4 + RES_NAME_LEN].split(b"\0")[0].decode()
            off, size = struct.unpack("<II", ent[4 + RES_NAME_LEN:4 + RES_NAME_LEN + 8])
            yield name, off * RES_BLOCK, size

    def get(self, name: str) -> tuple[int, int]:
        for n, off, size in self.entries():
            if n == name:
                return off, size
        raise KeyError(name)

    @staticmethod
    def build(entries: "list[tuple[str, bytes]]") -> bytes:
        """Compose a fresh resource image from (name, data) pairs.

        In-place replacement forces every payload to keep its exact vendor byte
        count, which in turn forces our logo to match the vendor's geometry.
        Building the image instead lets the logo be any size — and, critically,
        lets the whole resource stay small. A 943 616-byte resource (the stock
        one, with its two 480x198 logos) hangs this U-Boot before display init;
        465 408 bytes boots. See docs/my355/06-card-image-build.md.
        """
        header_blocks = 1
        entry_blocks = 1
        table = bytearray(header_blocks * RES_BLOCK + len(entries) * entry_blocks * RES_BLOCK)
        table[0:4] = RES_MAGIC
        table[8] = header_blocks
        table[9] = entry_blocks
        struct.pack_into("<H", table, 10, 1)
        struct.pack_into("<I", table, 12, len(entries))

        body = bytearray()
        cursor = len(table)                      # first free byte, block-aligned below
        for i, (name, data) in enumerate(entries):
            pad = (-cursor) % RES_BLOCK
            body += b"\0" * pad
            cursor += pad
            off_blocks = cursor // RES_BLOCK
            base = header_blocks * RES_BLOCK + i * entry_blocks * RES_BLOCK
            table[base:base + 4] = b"ENTR"
            encoded = name.encode()
            table[base + 4:base + 4 + len(encoded)] = encoded
            struct.pack_into("<II", table, base + 4 + RES_NAME_LEN, off_blocks, len(data))
            body += data
            cursor += len(data)
        blob = bytes(table) + bytes(body)
        return blob + b"\0" * ((-len(blob)) % RES_BLOCK)



def fdt_find_prop(dtb: bytes, node: str, prop: str) -> tuple[int, int]:
    """Return (offset, length) of `prop`'s value inside the last node named `node`."""
    if dtb[:4] != FDT_MAGIC:
        raise ValueError("not a device tree blob")
    off_struct, off_strings = struct.unpack(">II", dtb[8:16])
    size_strings, size_struct = struct.unpack(">II", dtb[32:40])
    strings = dtb[off_strings:off_strings + size_strings]
    p, end, path = off_struct, off_struct + size_struct, []
    while p < end:
        tok = struct.unpack(">I", dtb[p:p + 4])[0]
        p += 4
        if tok == 1:
            e = dtb.index(b"\0", p)
            path.append(dtb[p:e].decode() or "/")
            p = (e + 1 + 3) & ~3
        elif tok == 2:
            path.pop()
        elif tok == 3:
            length, nameoff = struct.unpack(">II", dtb[p:p + 8])
            p += 8
            name_end = strings.index(b"\0", nameoff)
            if strings[nameoff:name_end].decode() == prop and path[-1:] == [node]:
                return p, length
            p = (p + length + 3) & ~3
        elif tok == 9:
            break
    raise KeyError(f"{node}/{prop} not found")


def set_prop_string(dtb: bytes, node: str, prop: str, value: str) -> bytes:
    """Rewrite a string property in place, NUL-padded to its original length.

    Device tree string properties are read with strcmp semantics, so trailing
    NULs beyond the terminator are ignored — which lets a shorter value be
    substituted without relayout.
    """
    off, length = fdt_find_prop(dtb, node, prop)
    encoded = value.encode() + b"\0"
    if len(encoded) > length:
        raise ValueError(f"{node}/{prop}: '{value}' needs {len(encoded)} bytes, "
                         f"only {length} available; in-place patching cannot grow the FDT")
    b = bytearray(dtb)
    b[off:off + length] = encoded.ljust(length, b"\0")
    return bytes(b)


def fdt_find_bootargs(dtb: bytes) -> tuple[int, int]:
    """Return (offset, length) of /chosen/bootargs' value inside `dtb`."""
    if dtb[:4] != FDT_MAGIC:
        raise ValueError("not a device tree blob")
    off_struct, off_strings = struct.unpack(">II", dtb[8:16])
    size_strings, size_struct = struct.unpack(">II", dtb[32:40])
    strings = dtb[off_strings:off_strings + size_strings]
    p, end, path = off_struct, off_struct + size_struct, []
    while p < end:
        tok = struct.unpack(">I", dtb[p:p + 4])[0]
        p += 4
        if tok == 1:                                  # FDT_BEGIN_NODE
            e = dtb.index(b"\0", p)
            path.append(dtb[p:e].decode() or "/")
            p = (e + 1 + 3) & ~3
        elif tok == 2:                                # FDT_END_NODE
            path.pop()
        elif tok == 3:                                # FDT_PROP
            length, nameoff = struct.unpack(">II", dtb[p:p + 8])
            p += 8
            name_end = strings.index(b"\0", nameoff)
            if strings[nameoff:name_end] == b"bootargs" and path[-1:] == ["chosen"]:
                return p, length
            p = (p + length + 3) & ~3
        elif tok == 9:                                # FDT_END
            break
    raise KeyError("/chosen/bootargs not found")


def set_bootargs(dtb: bytes, new_args: str) -> bytes:
    """Rewrite /chosen/bootargs, space-padding to preserve the FDT layout."""
    off, length = fdt_find_bootargs(dtb)
    budget = length - 1                               # value includes its NUL
    if len(new_args) > budget:
        raise ValueError(
            f"bootargs too long: {len(new_args)} > {budget} chars. In-place "
            "patching cannot grow the FDT; shorten the command line.")
    padded = new_args.ljust(budget).encode() + b"\0"
    b = bytearray(dtb)
    b[off:off + length] = padded
    return bytes(b)


def rewrite_root(args_str: str, root: str, rootfstype: str | None,
                 drop: list[str] | None = None, append: str | None = None) -> str:
    """Rewrite a kernel command line: repoint root=, drop tokens, append tokens.

    `drop` holds token prefixes to remove — useful because the budget is tight
    (the vendor line uses every available byte) and `earlycon=...` is dead weight
    on a unit with no UART attached.
    """
    drop = drop or []
    out = []
    for tok in args_str.split():
        if any(tok.startswith(d) for d in drop):
            continue
        if tok.startswith("root="):
            out.append(f"root={root}")
        elif tok.startswith("rootfstype=") and rootfstype:
            out.append(f"rootfstype={rootfstype}")
        else:
            out.append(tok)
    if not any(t.startswith("root=") for t in out):
        out.append(f"root={root}")
    if append:
        out.extend(append.split())
    return " ".join(out)


def load(path: str) -> tuple[BootImage, ResourceImage, bytes]:
    boot = BootImage(open(path, "rb").read())
    res = ResourceImage(boot.second)
    off, size = res.get("rk-kernel.dtb")
    return boot, res, res.blob[off:off + size]


def cmd_info(a) -> int:
    boot, res, dtb = load(a.bootimg)
    print(f"boot image     {a.bootimg}")
    print(f"  page size    {boot.page_size}")
    print(f"  kernel       {boot.kernel_size} bytes @ {boot.kernel_off} "
          f"(load 0x{boot.kernel_addr:x})  sha256 {hashlib.sha256(boot.kernel).hexdigest()[:16]}…")
    print(f"  ramdisk      {boot.ramdisk_size} bytes")
    print(f"  second       {boot.second_size} bytes @ {boot.second_off}  (RSCE, {res.count} entries)")
    for name, off, size in res.entries():
        print(f"      {name:22s} {size:>8} bytes")
    ok = boot.compute_id() == boot.stored_id
    print(f"  image id     {boot.stored_id.hex()}  ({'valid' if ok else 'STALE'})")
    off, length = fdt_find_bootargs(dtb)
    cur = dtb[off:off + length].split(b"\0")[0].decode()
    print(f"  bootargs     ({len(cur)} chars used of {length - 1} available)")
    print(f"      {cur}")
    return 0


def cmd_extract(a) -> int:
    boot, res, _ = load(a.bootimg)
    os.makedirs(a.outdir, exist_ok=True)
    kpath = os.path.join(a.outdir, "kernel.Image")
    with open(kpath, "wb") as fh:
        fh.write(boot.kernel)
    print(f"  {kpath}  {boot.kernel_size} bytes")
    for name, off, size in res.entries():
        path = os.path.join(a.outdir, name)
        with open(path, "wb") as fh:
            fh.write(res.blob[off:off + size])
        print(f"  {path}  {size} bytes")
    return 0


def cmd_setargs(a) -> int:
    boot, res, dtb = load(a.bootimg)
    off, length = fdt_find_bootargs(dtb)
    old = dtb[off:off + length].split(b"\0")[0].decode()
    new = rewrite_root(old, a.root, a.rootfstype, a.drop, a.append)
    patched_dtb = set_bootargs(dtb, new)
    if a.led_trigger:
        patched_dtb = set_prop_string(patched_dtb, "work", "linux,default-trigger",
                                      a.led_trigger)
        print(f"  led: /leds/work default-trigger -> {a.led_trigger} "
              f"(kernel-side signal, fires at gpio-leds probe)")

    # Rebuild the resource image rather than patch it in place. The logo is then
    # free to be any size, and the whole resource can be kept small enough for
    # U-Boot's loader (see ResourceImage.build).
    logo = open(a.logo, "rb").read() if a.logo else None
    entries = []
    for name, off, size in res.entries():
        if name == "rk-kernel.dtb":
            entries.append((name, patched_dtb))
        elif logo is not None and name in ("logo.bmp", "logo_kernel.bmp"):
            entries.append((name, logo))
        else:
            entries.append((name, res.blob[off:off + size]))
    second = ResourceImage.build(entries)
    print(f"  resource: rebuilt, {boot.second_size} -> {len(second)} bytes "
          f"({len(second) // 512} blocks)")
    if len(second) > RESOURCE_SAFE_BYTES:
        print(f"  WARNING: resource is {len(second)} bytes; {RESOURCE_SAFE_BYTES} is the "
              f"largest size observed to boot. U-Boot hangs before display init above "
              f"some threshold between that and 943616.", file=sys.stderr)
    out = boot.rebuild(second)
    with open(a.out, "wb") as fh:
        fh.write(out)
    src = open(a.bootimg, "rb").read()
    changed = sum(1 for x, y in zip(src, out) if x != y)
    print(f"  old: {old}")
    print(f"  new: {new}")
    print(f"  wrote {a.out}  ({len(out)} bytes, {changed} bytes differ)")
    verify_boot, verify_res, verify_dtb = load(a.out)
    assert verify_boot.kernel == boot.kernel, "kernel changed — refusing"
    assert [n for n, _, _ in verify_res.entries()] == [n for n, _ in entries], \
        "resource entry set changed — refusing"
    assert verify_boot.compute_id() == verify_boot.stored_id, \
        "boot image id is stale — U-Boot would reject this"
    voff, vlen = fdt_find_bootargs(verify_dtb)
    assert verify_dtb[voff:voff + vlen].split(b"\0")[0].decode().strip() == new.strip()
    print(f"  image id refreshed: {verify_boot.stored_id.hex()}")
    print("  verified: kernel byte-identical, id valid, bootargs read back correctly")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("info", help="describe a boot image")
    p.add_argument("bootimg")
    p.set_defaults(fn=cmd_info)

    p = sub.add_parser("extract", help="unpack kernel and resource entries")
    p.add_argument("bootimg")
    p.add_argument("outdir")
    p.set_defaults(fn=cmd_extract)

    p = sub.add_parser("setargs", help="repoint root= and repack in place")
    p.add_argument("bootimg")
    p.add_argument("out")
    p.add_argument("--root", required=True, help="e.g. /dev/mmcblk1p4")
    p.add_argument("--rootfstype", default=None, help="e.g. ext4")
    p.add_argument("--drop", action="append", default=[],
                   metavar="PREFIX", help="remove tokens starting with PREFIX (repeatable)")
    p.add_argument("--append", default=None,
                   metavar="TOKENS", help='extra tokens, e.g. "console=tty0"')
    p.add_argument("--led-trigger", default=None, metavar="NAME",
                   help="set /leds/work linux,default-trigger (e.g. heartbeat)")
    p.add_argument("--logo", default=None, metavar="BMP",
                   help="replace logo.bmp/logo_kernel.bmp (must be the same byte size)")
    p.set_defaults(fn=cmd_setargs)

    a = ap.parse_args()
    try:
        return a.fn(a)
    except (ValueError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
