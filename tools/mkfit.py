#!/usr/bin/env python3
"""FIT images for the my355 (Miyoo Flip) boot path.

    mkfit.py uboot   the FIT the SPL loads from the card's `uboot` partition:
                     our U-Boot proper, with the vendor's BL31, OP-TEE and
                     control device tree byte-for-byte.
    mkfit.py boot    the FIT our U-Boot boots from the `boot` partition: the
                     kernel zstd-compressed and its device tree, behind a
                     512-byte header that carries its length.

The vendor secure world is kept whole on purpose: the DDR blob in mtd5 is paired
with its BL31, and the DMC driver reaches BL31 through Rockchip SIP calls.

Hand-rolled rather than mkimage: the `uboot` FIT mirrors the vendor's layout
rather than mkimage's, and the SPL checks a sha256 per image, which is worth
computing and re-checking here.

Usage:
    mkfit.py uboot VENDOR_FIT UBOOT_BIN OUT --uboot-load 0xa00000
    mkfit.py boot  IMAGE DTB OUT --release R --root /dev/mmcblk1p3
    mkfit.py addresses
    mkfit.py verify-uboot META ITB
    mkfit.py info  FIT
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys

SECTOR = 512
FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_END = 1, 2, 3, 9

# The sector in front of the boot FIT. `mmc read` needs a length, and the kernel
# changes size with every build, so the length travels with the payload.
BOOT_HDR_MAGIC = b"MY355FIT"
BOOT_HDR_VERSION = 1

# Where the vendor FIT puts its first payload; every later one is 512-aligned.
FIT_DATA_START = 0x1000

# The DRAM map, shared with the boot script build-uboot.sh generates. One source
# of truth, because an overlap here is a silent hang on a unit with no console.
KERNEL_LOAD_ADDR = 0x02000000   # decompressed kernel; 2 MiB-aligned per its header
FIT_LOAD_ADDR = 0x0A000000      # the boot FIT as read off the card
HDR_LOAD_ADDR = 0x0C000000      # its header sector
LOG_LOAD_ADDR = 0x0C100000      # the console record, staged for writing
# The console record goes to the last LOG_SECTORS of the active `boot` partition
# (debug builds only). The boot FIT must leave them free.
LOG_SECTORS = 128

# OP-TEE, resident for the life of the system, which mainline U-Boot does not
# describe: the device tree reserves it.
OPTEE = (0x08400000, 0x08400000 + 0x01000000)

# Tuned for decode speed with U-Boot's own decoder, not for size: a 256 KiB
# window stays in cache, min-match 6 means fewer, longer copies, and the frame
# checksum costs ~100 ms to verify (docs/uboot.md, "zstd").
ZSTD_ARGS = ["--ultra", "-22", "--no-check", "--zstd=wlog=18,mml=6", "-T1", "-q"]


def zstd(raw: bytes, *args: str) -> bytes:
    if shutil.which("zstd") is None:
        sys.exit("mkfit: needs the `zstd` CLI (apk add zstd)")
    return subprocess.run(["zstd", "-c", *args], input=raw,
                          stdout=subprocess.PIPE, check=True).stdout


# --------------------------------------------------------------------------
# device tree writing


class Node:
    """A device tree node under construction. Property order is preserved."""

    def __init__(self, name: str = "") -> None:
        self.name = name
        self.props: "list[tuple[str, bytes]]" = []
        self.children: "list[Node]" = []

    def raw(self, name: str, value: bytes) -> "Node":
        self.props.append((name, value))
        return self

    def string(self, name: str, value: str) -> "Node":
        return self.raw(name, value.encode() + b"\0")

    def u32(self, name: str, value: int) -> "Node":
        return self.raw(name, struct.pack(">I", value & 0xFFFFFFFF))

    def node(self, name: str) -> "Node":
        child = Node(name)
        self.children.append(child)
        return child


def build_fdt(root: Node) -> bytes:
    """Serialise `root` as a version 17 flattened device tree."""
    strings = bytearray()
    offsets: "dict[str, int]" = {}

    def string_off(name: str) -> int:
        if name not in offsets:
            offsets[name] = len(strings)
            strings.extend(name.encode() + b"\0")
        return offsets[name]

    body = bytearray()

    def emit(node: Node) -> None:
        body.extend(struct.pack(">I", FDT_BEGIN_NODE))
        raw = node.name.encode() + b"\0"
        body.extend(raw + b"\0" * (-len(raw) % 4))
        for name, value in node.props:
            body.extend(struct.pack(">III", FDT_PROP, len(value), string_off(name)))
            body.extend(value + b"\0" * (-len(value) % 4))
        for child in node.children:
            emit(child)
        body.extend(struct.pack(">I", FDT_END_NODE))

    emit(root)
    body.extend(struct.pack(">I", FDT_END))

    off_struct = 56                      # 40-byte header + one empty reserve entry
    off_strings = off_struct + len(body)
    total = off_strings + len(strings)
    header = struct.pack(">10I", FDT_MAGIC, total, off_struct, off_strings,
                         40, 17, 16, 0, len(strings), len(body))
    return header + b"\0" * 16 + bytes(body) + bytes(strings)


# --------------------------------------------------------------------------
# device tree reading — enough to take a FIT apart


def parse_fdt(blob: bytes) -> dict:
    """Return the tree as nested {"props": {name: bytes}, "nodes": {name: ...}}."""
    if struct.unpack(">I", blob[:4])[0] != FDT_MAGIC:
        raise ValueError("not a device tree blob")
    off_struct, off_strings = struct.unpack(">II", blob[8:16])
    size_strings, size_struct = struct.unpack(">II", blob[32:40])
    strings = blob[off_strings:off_strings + size_strings]

    def name_at(off: int) -> str:
        return strings[off:strings.index(b"\0", off)].decode()

    root: dict = {"props": {}, "nodes": {}}
    stack = [root]
    p, end = off_struct, off_struct + size_struct
    while p < end:
        tag = struct.unpack(">I", blob[p:p + 4])[0]
        p += 4
        if tag == FDT_BEGIN_NODE:
            e = blob.index(b"\0", p)
            name = blob[p:e].decode()
            p = (e + 1 + 3) & ~3
            child: dict = {"props": {}, "nodes": {}}
            stack[-1]["nodes"][name] = child
            stack.append(child)
        elif tag == FDT_END_NODE:
            stack.pop()
        elif tag == FDT_PROP:
            length, nameoff = struct.unpack(">II", blob[p:p + 8])
            p += 8
            stack[-1]["props"][name_at(nameoff)] = blob[p:p + length]
            p = (p + length + 3) & ~3
        elif tag == FDT_END:
            break
    # The sentinel's only child is the tree's own, unnamed, root node.
    return root["nodes"].get("", root)


def as_string(value: bytes) -> str:
    return value.split(b"\0")[0].decode()


def as_stringlist(value: bytes) -> "list[str]":
    return [s.decode() for s in value.rstrip(b"\0").split(b"\0") if s]


def image_data(fit: bytes, image: dict) -> bytes:
    """The payload of one FIT image, external or inline."""
    props = image["props"]
    if "data" in props:
        return props["data"]
    size = struct.unpack(">I", props["data-size"])[0]
    if "data-position" in props:                       # absolute, as the vendor has it
        off = struct.unpack(">I", props["data-position"])[0]
    else:                                              # relative to the end of the tree
        total = struct.unpack(">I", fit[4:8])[0]
        off = ((total + 3) & ~3) + struct.unpack(">I", props["data-offset"])[0]
    return fit[off:off + size]


# --------------------------------------------------------------------------
# mkfit.py uboot

# Carried from each vendor image node to ours. `load` is rewritten for U-Boot
# itself and copied for everything else.
CARRY_PROPS = ("description", "type", "arch", "os", "compression", "load", "entry")


def cmd_uboot(a) -> int:
    vendor = open(a.vendor_fit, "rb").read()
    uboot = open(a.uboot_bin, "rb").read()
    if uboot[:4] == b"\x7fELF":
        sys.exit("mkfit: expected u-boot.bin, got an ELF")

    tree = parse_fdt(vendor)
    images = tree["nodes"]["images"]["nodes"]
    configs = tree["nodes"]["configurations"]
    conf = configs["nodes"][as_string(configs["props"]["default"])]["props"]
    firmware = as_string(conf["firmware"])
    loadables = as_stringlist(conf["loadables"])
    fdt_name = as_string(conf["fdt"]) if "fdt" in conf else None
    if "uboot" not in images or "uboot" not in loadables:
        sys.exit("mkfit: the vendor FIT has no `uboot` loadable to replace")

    print(f"vendor FIT     {a.vendor_fit}")
    print(f"  config       firmware={firmware} loadables={' '.join(loadables)} fdt={fdt_name}")

    payloads: "list[tuple[str, bytes, dict]]" = []
    for name in images:
        props = dict(images[name]["props"])
        data = image_data(vendor, images[name])
        if name == "uboot":
            data = uboot
            props["load"] = struct.pack(">I", a.uboot_load)
        payloads.append((name, data, props))

    def compose(positions: "list[int]", totalsize: int) -> bytes:
        root = Node("")
        root.u32("version", 0)
        root.u32("totalsize", totalsize)
        root.string("description", "BaseOS my355 U-Boot with the vendor ATF")
        root.u32("#address-cells", 1)
        node_images = root.node("images")
        for (name, data, props), pos in zip(payloads, positions):
            img = node_images.node(name)
            img.u32("data-size", len(data))
            img.u32("data-position", pos)
            for key in CARRY_PROPS:
                if key in props:
                    img.raw(key, props[key])
            img.node("hash").raw("value", hashlib.sha256(data).digest()) \
                            .string("algo", "sha256")
        node_conf = root.node("configurations")
        node_conf.string("default", "conf")
        one = node_conf.node("conf")
        one.string("description", "BaseOS my355")
        one.u32("rollback-index", 0)
        one.string("firmware", firmware)
        one.raw("loadables", b"".join(n.encode() + b"\0" for n in loadables))
        if fdt_name:
            one.string("fdt", fdt_name)
        # No signature node: the vendor SPL checks hashes only ("Verified-boot: 0").
        return build_fdt(root)

    # Two passes. Everything written between them is a fixed-width cell, so the
    # tree carrying the real offsets is exactly as long as the probe.
    probe = compose([0] * len(payloads), 0)
    if len(probe) > FIT_DATA_START:
        sys.exit(f"mkfit: the tree is {len(probe)} bytes, past the first payload "
                 f"at {FIT_DATA_START}")
    cursor, positions = FIT_DATA_START, []
    for _name, data, _props in payloads:
        positions.append(cursor)
        cursor = (cursor + len(data) + SECTOR - 1) // SECTOR * SECTOR
    blob = compose(positions, cursor)
    if len(blob) != len(probe):
        sys.exit("mkfit: tree length moved between passes")

    out = bytearray(cursor)
    out[0:len(blob)] = blob
    for (name, data, _props), pos in zip(payloads, positions):
        out[pos:pos + len(data)] = data
        print(f"  {name:8s} {len(data):>9} bytes @ 0x{pos:06x}"
              f"{'   <- ours' if name == 'uboot' else ''}")
    with open(a.out, "wb") as fh:
        fh.write(out)

    check = parse_fdt(bytes(out))["nodes"]["images"]["nodes"]
    for name, image in check.items():
        data = image_data(bytes(out), image)
        assert hashlib.sha256(data).digest() == image["nodes"]["hash"]["props"]["value"], \
            f"{name}: sha256 mismatch"
        expect = uboot if name == "uboot" else image_data(vendor, images[name])
        assert data == expect, f"{name}: payload is not what was written"
    print(f"  wrote {a.out}  ({len(out)} bytes)")
    print(f"  verified: sha256 per image, U-Boot at 0x{a.uboot_load:x}, "
          f"{len(check) - 1} vendor payloads byte-identical")
    return 0


# --------------------------------------------------------------------------
# mkfit.py boot


def check_dram_map(image_size: int, fit_bytes: int) -> None:
    """Refuse any overlap between the regions the boot script and bootm use."""
    regions = [
        ("kernel", KERNEL_LOAD_ADDR, KERNEL_LOAD_ADDR + image_size),
        ("FIT", FIT_LOAD_ADDR, FIT_LOAD_ADDR + fit_bytes),
        ("header", HDR_LOAD_ADDR, HDR_LOAD_ADDR + SECTOR),
        ("log", LOG_LOAD_ADDR, LOG_LOAD_ADDR + LOG_SECTORS * SECTOR),
        # Writes there are a silent drop or an abort, not a corruption we see.
        ("OP-TEE", *OPTEE),
    ]
    for i, (name, lo, hi) in enumerate(regions):
        for other, olo, ohi in regions[i + 1:]:
            if lo < ohi and olo < hi:
                sys.exit(f"mkfit: the {name} at 0x{lo:x}..0x{hi:x} overlaps the "
                         f"{other} at 0x{olo:x}..0x{ohi:x}")


def check_dtb(dtb: bytes, root: str) -> str:
    """The tree carries the command line and the OP-TEE reservation; check both."""
    tree = parse_fdt(dtb)
    bootargs = as_string(tree["nodes"]["chosen"]["props"].get("bootargs", b""))
    if f"root={root}" not in bootargs.split():
        sys.exit(f"mkfit: the device tree's bootargs do not say root={root}: {bootargs!r}")
    reserved = tree["nodes"].get("reserved-memory", {"nodes": {}})["nodes"]
    optee = reserved.get(f"optee@{OPTEE[0]:x}", {"props": {}})["props"]
    if optee.get("reg") != struct.pack(">QQ", OPTEE[0], OPTEE[1] - OPTEE[0]) \
            or "no-map" not in optee:
        sys.exit("mkfit: the device tree does not reserve OP-TEE as no-map")
    return bootargs


def cmd_boot(a) -> int:
    raw = open(a.kernel, "rb").read()
    dtb = open(a.dtb, "rb").read()
    if raw[56:60] != b"ARM\x64":
        sys.exit("mkfit: the kernel is not an arm64 Image")
    bootargs = check_dtb(dtb, a.root)
    print(f"kernel {a.kernel} ({a.release}), {a.dtb}")
    print(f"  bootargs: {bootargs}")

    # image_size includes the BSS cleared past the end of the file.
    image_size = struct.unpack_from("<Q", raw, 16)[0]
    payload = zstd(raw, *ZSTD_ARGS)
    assert zstd(payload, "-d", "-q") == raw, "compressed kernel does not round-trip"
    print(f"  kernel: zstd {len(raw)} -> {len(payload)} bytes "
          f"({100 * len(payload) / len(raw):.0f}%)")

    root = Node("")
    root.string("description", "BaseOS my355")
    # Mandatory once a build has CMD_DATE; fixed, so the FIT reproduces.
    root.u32("timestamp", 0)
    root.u32("#address-cells", 1)
    node_images = root.node("images")
    kernel = node_images.node("kernel")
    kernel.string("description", f"Linux {a.release}")
    kernel.string("type", "kernel")
    kernel.string("os", "linux")
    kernel.string("arch", "arm64")
    kernel.string("compression", "zstd")
    kernel.u32("load", KERNEL_LOAD_ADDR)
    kernel.u32("entry", KERNEL_LOAD_ADDR)
    kernel.raw("data", payload)
    # The command line rides in the tree: fdt_chosen() only rewrites
    # /chosen/bootargs when the `bootargs` variable is set, and ours never is.
    fdt = node_images.node("fdt")
    fdt.string("description", os.path.basename(a.dtb))
    fdt.string("type", "flat_dt")
    fdt.string("arch", "arm64")
    fdt.string("compression", "none")
    fdt.raw("data", dtb)
    # No hash nodes: bootm treats them as optional, and a sha256 over the whole
    # kernel is the kind of work this path exists to delete.
    node_conf = root.node("configurations")
    node_conf.string("default", "conf")
    one = node_conf.node("conf")
    one.string("description", "BaseOS my355")
    one.string("kernel", "kernel")
    one.string("fdt", "fdt")

    blob = build_fdt(root)
    blob += b"\0" * (-len(blob) % SECTOR)
    sectors = len(blob) // SECTOR
    check_dram_map(image_size, len(blob))
    if a.slot_sectors and 1 + sectors > a.slot_sectors - LOG_SECTORS:
        sys.exit(f"mkfit: header + FIT is {1 + sectors} sectors; the slot holds "
                 f"{a.slot_sectors} less {LOG_SECTORS} for the log")

    header = bytearray(SECTOR)
    struct.pack_into("<8sIII", header, 0, BOOT_HDR_MAGIC, sectors, len(blob),
                     BOOT_HDR_VERSION)
    with open(a.out, "wb") as fh:
        fh.write(bytes(header) + blob)

    got = parse_fdt(blob)["nodes"]["images"]["nodes"]
    assert zstd(image_data(blob, got["kernel"]), "-d", "-q") == raw, \
        "kernel does not round-trip out of the written FIT"
    assert image_data(blob, got["fdt"]) == dtb, "device tree not readable back"
    print(f"  wrote {a.out}: header + {sectors} sectors ({SECTOR + len(blob)} bytes)")
    return 0


# --------------------------------------------------------------------------


def addresses() -> "dict[str, str]":
    """The values build-uboot.sh bakes into CONFIG_BOOTCOMMAND."""
    magic = struct.unpack("<II", BOOT_HDR_MAGIC)
    return {
        "MY355_FIT_ADDR": f"{FIT_LOAD_ADDR:x}",
        "MY355_HDR_ADDR": f"{HDR_LOAD_ADDR:x}",
        "MY355_HDR_MAGIC0": f"{magic[0]:x}",
        "MY355_HDR_MAGIC1": f"{magic[1]:x}",
        "MY355_HDR_COUNT_ADDR": f"{HDR_LOAD_ADDR + len(BOOT_HDR_MAGIC):x}",
        "MY355_LOG_ADDR": f"{LOG_LOAD_ADDR:x}",
        "MY355_LOG_SECTORS": f"{LOG_SECTORS:x}",
        "MY355_LOG_BYTES": f"{LOG_SECTORS * SECTOR:x}",
    }


def cmd_addresses(_a) -> int:
    for key, value in addresses().items():
        print(f"{key}={value}")
    return 0


def cmd_verify_uboot(a) -> int:
    """Check a built `uboot` FIT still matches this tool's DRAM map and header.

    The boot script bakes those in at build time; if they have moved since,
    U-Boot reads the wrong place, and on this unit the only symptom is a card
    that does not boot.
    """
    meta = json.load(open(a.meta))
    got = hashlib.sha256(open(a.itb, "rb").read()).hexdigest()
    problems = []
    if got != meta.get("sha256"):
        problems.append(f"{a.itb} is {got[:16]}…, built as {meta.get('sha256', '?')[:16]}…")
    if meta.get("addresses") != addresses():
        problems.append("built against a different DRAM map or header")
    for line in problems:
        print(f"  stale U-Boot build: {line}", file=sys.stderr)
    if problems:
        print("  rebuild it: ./build-uboot.sh", file=sys.stderr)
        return 1
    print(f"  {meta.get('banner')}{' (debug)' if meta.get('debug') else ''}")
    return 0


def cmd_info(a) -> int:
    blob = open(a.fit, "rb").read()
    if blob[:8] == BOOT_HDR_MAGIC:
        sectors, size, version = struct.unpack_from("<III", blob, 8)
        print(f"  header       v{version}, {size} bytes in {sectors} sectors")
        blob = blob[SECTOR:]
    tree = parse_fdt(blob)
    print(f"  description  {as_string(tree['props'].get('description', b''))!r}")
    for name, image in tree["nodes"]["images"]["nodes"].items():
        props = image["props"]
        bits = [f"{len(image_data(blob, image))} bytes"]
        if "load" in props:
            bits.append(f"load 0x{struct.unpack('>I', props['load'])[0]:x}")
        if "compression" in props:
            bits.append(as_string(props["compression"]))
        print(f"  {name:10s} {', '.join(bits)}")
    for name, one in tree["nodes"]["configurations"]["nodes"].items():
        for key, value in one["props"].items():
            if key in ("firmware", "loadables", "fdt", "kernel"):
                print(f"  {name}/{key}: {' '.join(as_stringlist(value))}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("uboot", help="FIT for the card's `uboot` partition")
    p.add_argument("vendor_fit", help="stock U-Boot FIT (prepared/uboot.img)")
    p.add_argument("uboot_bin", help="our u-boot.bin")
    p.add_argument("out")
    p.add_argument("--uboot-load", type=lambda s: int(s, 0), required=True,
                   help="the build's CONFIG_TEXT_BASE")
    p.set_defaults(func=cmd_uboot)

    p = sub.add_parser("boot", help="FIT for the card's `boot` partition")
    p.add_argument("kernel", help="arm64 Image (work/my355/kernel/Image)")
    p.add_argument("dtb", help="work/my355/kernel/rk3566-miyoo-flip.dtb")
    p.add_argument("out")
    p.add_argument("--release", required=True, help="the kernel release, for the FIT")
    p.add_argument("--root", required=True, help="the root= the device tree must name")
    p.add_argument("--slot-sectors", type=int, default=0,
                   help="refuse a FIT that does not leave the log sectors free")
    p.set_defaults(func=cmd_boot)

    p = sub.add_parser("addresses", help="the DRAM map and header, as shell variables")
    p.set_defaults(func=cmd_addresses)

    p = sub.add_parser("verify-uboot", help="check a built FIT against this tool")
    p.add_argument("meta", help="work/my355/uboot-mainline.json")
    p.add_argument("itb", help="work/my355/uboot-mainline.itb")
    p.set_defaults(func=cmd_verify_uboot)

    p = sub.add_parser("info", help="describe a FIT")
    p.add_argument("fit")
    p.set_defaults(func=cmd_info)

    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    raise SystemExit(main())
