#!/usr/bin/env python3
"""Synthesise a my355-shaped preloader for tests/test-preloader-patch.sh.

Two RKNS copies, a DDR blob and an SPL payload whose device tree carries the
stripped /pinctrl node this port exists to repair — the shape both patchers
expect, without shipping a vendor preloader (docs/boot-chain.md).

    make_preloader_fixture.py OUT.img
"""
import hashlib, struct, sys

def fdt(nodes):
    strings = bytearray()
    def stroff(name):
        probe = name.encode() + b"\0"
        at = 0 if strings.startswith(probe) else bytes(strings).find(b"\0" + probe)
        if at == 0 and strings.startswith(probe):
            return 0
        if at > 0:
            return at + 1
        off = len(strings)
        strings.extend(probe)
        return off
    body = bytearray()
    def begin(name):
        body.extend(struct.pack(">I", 1))
        n = name.encode() + b"\0"
        body.extend(n + b"\0" * ((-len(n)) % 4))
    def prop(name, value):
        body.extend(struct.pack(">III", 3, len(value), stroff(name)))
        body.extend(value + b"\0" * ((-len(value)) % 4))
    def end():
        body.extend(struct.pack(">I", 2))
    begin("")
    prop("#address-cells", struct.pack(">I", 2))
    for name, props in nodes:
        begin(name)
        for pn, pv in props:
            prop(pn, pv)
        end()
    end()
    body.extend(struct.pack(">I", 9))                      # FDT_END
    off_struct = 56
    off_strings = off_struct + len(body)
    total = off_strings + len(strings)
    head = struct.pack(">10I", 0xD00DFEED, total, off_struct, off_strings,
                       40, 17, 16, 0, len(strings), len(body))
    return head + b"\0" * 16 + bytes(body) + bytes(strings)

u32 = lambda v: struct.pack(">I", v)
order = b"/sdhci@fe310000\0/dwmmc@fe2b0000\0/sfc@fe300000/flash@0\0"
dtb = fdt([
    ("pinctrl", []),                                       # the stripped node
    ("syscon@fdc60000", [("phandle", u32(0x1000001B)), ("u-boot,dm-spl", b"")]),
    ("syscon@fdc20000", [("phandle", u32(0x100000DC)), ("u-boot,dm-spl", b"")]),
    ("dwmmc@fe2b0000", [("pinctrl-0", u32(0x100000DE)), ("pinctrl-names", b"default\0"),
                        ("u-boot,dm-spl", b"")]),
    ("chosen", [("u-boot,spl-boot-order", order)]),
])

SECTOR, SIZE = 512, 2 * 1024 * 1024
img = bytearray(SIZE)
ddr = (b"DDR V1.18 f366f69a7d rk3566_ddr_1056MHz " * 64).ljust(108 * SECTOR, b"\x5a")
# As on the device: SPL code, then the device tree, then zero slack.
spl = (b"U-Boot SPL 2017.09 (Dec 12 2024 - 10:17:54)" * 5000).ljust(239064, b"\xa5")
spl = spl + dtb
spl = spl.ljust(480 * SECTOR, b"\0")
for base in (0x20000, 0x80000):
    img[base:base + 4] = b"RKNS"
    for i, (off, cnt, payload) in enumerate(((4, 108, ddr), (112, 480, spl))):
        e = base + 0x78 + i * 0x58
        struct.pack_into("<HH", img, e, off, cnt)
        img[base + off * SECTOR:base + off * SECTOR + len(payload)] = payload
        img[e + 0x18:e + 0x18 + 32] = hashlib.sha256(payload).digest()
open(sys.argv[1], "wb").write(bytes(img))
print(f"fixture: {sys.argv[1]} ({len(img)} bytes, dtb {len(dtb)} bytes)")
