#!/usr/bin/env python3
"""Repair the stock my355 preloader's SPL device tree so it can read an SD card.

fdtgrep stripped /pinctrl to an empty skeleton in every Miyoo build, so no pinctrl
driver binds and dwmmc@fe2b0000's pinctrl-0 is never applied. This restores the nine
properties Rockchip's own loaders carry on that node, and nothing else: the DDR blob,
the SPL code and the boot order stay the vendor's.

Rationale, container format and the flashing procedure: docs/02-sd-boot.md.

    mkpreloader.py IN.img OUT.img     patch, verify, write
    mkpreloader.py --verify IMG.img   re-check an image
"""

from __future__ import annotations

import argparse
import hashlib
import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9

IDB_COPIES = (0x20000, 0x80000)
IDB_TABLE, IDB_STRIDE, IDB_HASH = 0x78, 0x58, 0x18
SECTOR = 512
PRELOADER_BYTES = 2 * 1024 * 1024

GRF_PHANDLE = 0x1000001B         # syscon@fdc60000
PMUGRF_PHANDLE = 0x100000DC      # syscon@fdc20000
PINCTRL_PHANDLE = 0x100000DD     # the value /pinctrl's children already reference


def _u32(v: int) -> bytes:
    return struct.pack(">I", v)


# u-boot,dm-spl rather than Rockchip's dm-pre-reloc: that is what stock's own bound
# nodes use, and this SPL vintage checks the marker at runtime.
PINCTRL_PROPS = [
    ("compatible", b"rockchip,rk3568-pinctrl\0"),
    ("rockchip,grf", _u32(GRF_PHANDLE)),
    ("rockchip,pmu", _u32(PMUGRF_PHANDLE)),
    ("#address-cells", _u32(2)),
    ("#size-cells", _u32(2)),
    ("ranges", b""),
    ("u-boot,dm-spl", b""),
    ("status", b"okay\0"),
    ("phandle", _u32(PINCTRL_PHANDLE)),
]


class Fdt:
    """Just enough flattened-device-tree surgery to add properties to one node."""

    def __init__(self, blob: bytes) -> None:
        if blob[:4] != _u32(FDT_MAGIC):
            raise ValueError("not a device tree blob")
        f = struct.unpack(">10I", blob[:40])
        self.blob = blob
        self.totalsize, self.off_struct, self.off_strings = f[1], f[2], f[3]
        self.off_rsvmap, self.version, self.last_comp = f[4], f[5], f[6]
        self.boot_cpu, self.size_strings, self.size_struct = f[7], f[8], f[9]

    def walk(self):
        strings = self.blob[self.off_strings:self.off_strings + self.size_strings]
        p, end, path = self.off_struct, self.off_struct + self.size_struct, []
        while p < end:
            tok = struct.unpack(">I", self.blob[p:p + 4])[0]
            p += 4
            if tok == FDT_BEGIN_NODE:
                e = self.blob.index(b"\0", p)
                path.append(self.blob[p:e].decode())
                p = (e + 1 + 3) & ~3
            elif tok == FDT_END_NODE:
                path.pop()
            elif tok == FDT_PROP:
                length, nameoff = struct.unpack(">II", self.blob[p:p + 8])
                p += 8
                end_name = strings.index(b"\0", nameoff)
                yield ("/" + "/".join(path[1:]),
                       strings[nameoff:end_name].decode(), self.blob[p:p + length])
                p = (p + length + 3) & ~3
            elif tok == FDT_NOP:
                pass
            elif tok == FDT_END:
                break
            else:
                raise ValueError(f"bad FDT token 0x{tok:x} at 0x{p - 4:x}")

    def props(self) -> dict:
        return {f"{path}|{name}": val for path, name, val in self.walk()}

    def add_props(self, node_name: str, props) -> tuple[bytes, list]:
        struct_blk = self.blob[self.off_struct:self.off_struct + self.size_struct]
        strings = bytearray(self.blob[self.off_strings:
                                      self.off_strings + self.size_strings])
        rsvmap = self.blob[self.off_rsvmap:self.off_struct]

        p, depth, insert_at = 0, 0, None
        while p < len(struct_blk):
            tok = struct.unpack(">I", struct_blk[p:p + 4])[0]
            if tok == FDT_BEGIN_NODE:
                e = struct_blk.index(b"\0", p + 4)
                name = struct_blk[p + 4:e].decode()
                nxt = (e + 1 + 3) & ~3
                depth += 1
                if depth == 2 and name == node_name:
                    insert_at = nxt              # properties must precede subnodes
                    break
                p = nxt
            elif tok == FDT_END_NODE:
                depth -= 1
                p += 4
            elif tok == FDT_PROP:
                length = struct.unpack(">I", struct_blk[p + 4:p + 8])[0]
                p = (p + 12 + length + 3) & ~3
            elif tok == FDT_NOP:
                p += 4
            else:
                break
        if insert_at is None:
            raise KeyError(f"/{node_name} not found")

        def nameoff(name: str) -> tuple[int, bool]:
            probe = name.encode() + b"\0"
            i = bytes(strings).find(probe)
            while i > 0 and strings[i - 1] != 0:     # must be a whole entry
                i = bytes(strings).find(probe, i + 1)
            if i >= 0:
                return i, False
            off = len(strings)
            strings.extend(probe)
            return off, True

        blob, appended = bytearray(), []
        for name, value in props:
            off, is_new = nameoff(name)
            if is_new:
                appended.append(name)
            blob += struct.pack(">III", FDT_PROP, len(value), off)
            blob += value + b"\0" * ((-len(value)) % 4)

        new_struct = struct_blk[:insert_at] + bytes(blob) + struct_blk[insert_at:]
        off_struct = 40 + len(rsvmap)
        off_strings = off_struct + len(new_struct)
        header = struct.pack(">10I", FDT_MAGIC, off_strings + len(strings),
                             off_struct, off_strings, 40, self.version,
                             self.last_comp, self.boot_cpu,
                             len(strings), len(new_struct))
        return header + rsvmap + new_struct + bytes(strings), appended


def idb_entries(image: bytes, base: int):
    """Yield (index, start, length, stored_sha256, entry_offset) for one IDB copy."""
    if image[base:base + 4] != b"RKNS":
        raise ValueError(f"no RKNS magic at 0x{base:x}")
    for i in range(2):
        e = base + IDB_TABLE + i * IDB_STRIDE
        soff, scnt = struct.unpack("<HH", image[e:e + 4])
        yield i + 1, base + soff * SECTOR, scnt * SECTOR, \
            image[e + IDB_HASH:e + IDB_HASH + 32], e


def patch(src: bytes) -> tuple[bytes, list]:
    if len(src) != PRELOADER_BYTES:
        raise ValueError(f"expected a {PRELOADER_BYTES}-byte preloader, got {len(src)}")
    out, notes = bytearray(src), []
    for base in IDB_COPIES:
        for idx, start, length, stored, entry in idb_entries(src, base):
            if hashlib.sha256(src[start:start + length]).digest() != stored:
                raise ValueError(f"copy@0x{base:x} entry{idx}: input SHA-256 already "
                                 f"does not match; refusing to touch this image")
            if idx != 2:
                continue
            img = bytes(out[start:start + length])
            rel = img.find(_u32(FDT_MAGIC))
            if rel <= 0:
                raise ValueError("no device tree found inside the SPL image")
            fdt = Fdt(img[rel:])
            old = img[rel:rel + fdt.totalsize]
            if "/pinctrl|compatible" in Fdt(old).props():
                raise ValueError("/pinctrl already has a compatible; already patched?")
            tail = img[rel + fdt.totalsize:]
            if tail.strip(b"\0"):
                raise ValueError("non-zero data follows the device tree; refusing")
            new, appended = Fdt(old).add_props("pinctrl", PINCTRL_PROPS)
            grow = len(new) - len(old)
            if grow > len(tail):
                raise ValueError(f"device tree grows {grow} B but only {len(tail)} B "
                                 f"of slack; the image size would have to change")
            patched = img[:rel] + new + b"\0" * (length - rel - len(new))
            out[start:start + length] = patched
            out[entry + IDB_HASH:entry + IDB_HASH + 32] = \
                hashlib.sha256(patched).digest()
            notes.append((base, len(old), len(new), grow, len(tail), appended))
    return bytes(out), notes


def verify(orig: bytes, new: bytes) -> list:
    r = []
    add = lambda ok, msg: r.append((bool(ok), msg))

    add(len(new) == len(orig) == PRELOADER_BYTES, f"size unchanged at {len(new)} bytes")
    for base in IDB_COPIES:
        for idx, start, length, stored, _ in idb_entries(new, base):
            add(hashlib.sha256(new[start:start + length]).digest() == stored,
                f"copy@0x{base:x} entry{idx} SHA-256 matches its {length} bytes")

    e1 = list(idb_entries(new, IDB_COPIES[0]))[0]
    o1 = list(idb_entries(orig, IDB_COPIES[0]))[0]
    add(new[e1[1]:e1[1] + e1[2]] == orig[o1[1]:o1[1] + o1[2]], "DDR blob byte-identical")
    add(b"DDR V1.18 f366f69a7d" in new, "DDR V1.18 blob still in place")
    add(b"DDR Version V1.10" not in new, "no GammaLoader V1.10 blob introduced")

    span = list(idb_entries(new, IDB_COPIES[0]))[-1]
    end = span[1] + span[2] - IDB_COPIES[0]
    add(new[IDB_COPIES[0]:IDB_COPIES[0] + end] == new[IDB_COPIES[1]:IDB_COPIES[1] + end],
        "the two IDB copies remain identical to each other")

    _, s, l, _, _ = list(idb_entries(new, IDB_COPIES[0]))[1]
    rel = new[s:s + l].find(_u32(FDT_MAGIC))
    add(new[s:s + rel] == orig[s:s + rel],
        f"SPL code before the device tree byte-identical ({rel} bytes)")

    op, np_ = Fdt(orig[s + rel:]).props(), Fdt(new[s + rel:]).props()
    added = sorted(set(np_) - set(op))
    add(not (set(op) - set(np_)), "no property removed")
    add(not [k for k in op if op[k] != np_[k]], "no existing property altered")
    add(all(k.startswith("/pinctrl|") for k in added),
        f"all {len(added)} added properties are on /pinctrl")
    for name, value in PINCTRL_PROPS:
        add(np_.get(f"/pinctrl|{name}") == value, f"/pinctrl {name} set correctly")
    add(np_.get("/dwmmc@fe2b0000|pinctrl-0") is not None,
        "dwmmc@fe2b0000 still declares pinctrl-0")
    add(np_.get("/syscon@fdc60000|phandle") == _u32(GRF_PHANDLE), "GRF phandle resolves")
    add(np_.get("/syscon@fdc20000|phandle") == _u32(PMUGRF_PHANDLE),
        "PMUGRF phandle resolves")
    add(np_.get("/chosen|u-boot,spl-boot-order") ==
        op.get("/chosen|u-boot,spl-boot-order"), "boot order untouched")
    order = np_.get("/chosen|u-boot,spl-boot-order", b"").split(b"\0")
    add(b"/dwmmc@fe2b0000" in order and b"/sfc@fe300000/flash@0" in order and
        order.index(b"/dwmmc@fe2b0000") < order.index(b"/sfc@fe300000/flash@0"),
        "boot order still prefers the SD slot over SPI NAND")
    return r


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("src", metavar="IN.img", help="this unit's own mtd5 dump")
    ap.add_argument("out", metavar="OUT.img", nargs="?")
    ap.add_argument("--verify", action="store_true", help="only re-check IN.img")
    a = ap.parse_args()

    src = open(a.src, "rb").read()
    if a.verify:
        results = [(hashlib.sha256(src[s:s + l]).digest() == h,
                    f"copy@0x{b:x} entry{i} SHA-256 matches")
                   for b in IDB_COPIES for i, s, l, h, _ in idb_entries(src, b)]
    else:
        if not a.out:
            ap.error("OUT.img is required unless --verify is given")
        try:
            new, notes = patch(src)
        except (ValueError, KeyError) as exc:
            print(f"refusing to patch: {exc}", file=sys.stderr)
            return 1
        for base, o, n, grow, slack, appended in notes:
            print(f"  IDB copy @0x{base:x}: device tree {o} -> {n} bytes (+{grow}), "
                  f"{slack} bytes of slack"
                  + (f", strings appended: {', '.join(appended)}" if appended else ""))
        results = verify(src, new)

    print()
    for ok, msg in results:
        print(f"  [{'PASS' if ok else 'FAIL'}] {msg}")
    if not all(ok for ok, _ in results):
        print("\nverification FAILED — nothing written", file=sys.stderr)
        return 1
    if not a.verify:
        open(a.out, "wb").write(new)
        print(f"\nwrote {a.out}  ({len(new)} bytes, md5 {hashlib.md5(new).hexdigest()})")
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
