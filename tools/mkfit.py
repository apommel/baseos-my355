#!/usr/bin/env python3
"""FIT images for the my355 (Miyoo Flip) mainline U-Boot path.

Two images, built by one tool because they share a device tree writer:

    mkfit.py uboot   the FIT the SPL loads from the card's `uboot` partition —
                     our mainline U-Boot proper, carrying the vendor's BL31,
                     OP-TEE and U-Boot control device tree byte-for-byte.

    mkfit.py boot    the FIT that U-Boot then boots — the vendor kernel
                     (compressed) and the patched rk-kernel.dtb, behind a
                     512-byte header recording its length, so U-Boot reads
                     exactly as many sectors as there are (docs/09-uboot.md).

Why the vendor's ATF and not a fresh rkbin BL31: the DDR blob in `mtd5` is
paired with the unit, BL31 sits behind it, and the vendor 5.10 BSP kernel
reaches BL31 for DMC/DVFS through Rockchip SIP calls that mainline TF-A does
not implement. Keeping the whole secure-world stack exactly as stock ships it
makes U-Boot the only variable this change introduces.

Why hand-rolled rather than mkimage: the repository already parses and edits
FDTs in tools/rkbootimg.py without a dtc dependency, the `uboot` FIT has to be
laid out to mirror the vendor's structure rather than mkimage's defaults, and
the SPL verifies sha256 per image — which is worth computing and re-checking
here rather than trusting an external tool.

Usage:
    mkfit.py uboot VENDOR_FIT UBOOT_BIN OUT --uboot-load 0x800000
    mkfit.py boot  BOOTIMG OUT --root /dev/mmcblk1p3 --rootfstype ext4
    mkfit.py info  FIT
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import struct
import subprocess
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rkbootimg as rk                                          # noqa: E402

SECTOR = 512
FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_END = 1, 2, 3, 9

# The header sector in front of the boot FIT. U-Boot's `mmc read` needs a length
# and the kernel's size changes with every compression change, so the length
# travels with the payload instead of being baked into CONFIG_BOOTCOMMAND.
BOOT_HDR_MAGIC = b"MY355FIT"
BOOT_HDR_VERSION = 1

# Where the vendor FIT puts its first payload. Mirrored so the SPL sees the same
# shape it does today; every later image is 512-aligned behind it.
FIT_DATA_START = 0x1000

# The DRAM map the mainline path uses, shared between CONFIG_BOOTCOMMAND (which
# names the two read addresses) and the boot FIT (which names the load ones).
# One source of truth, because a silent overlap between the compressed payload
# and where the kernel decompresses is a hang with no console to report it.
#
#   0x02000000  kernel, decompressed — 2 MiB-aligned, per the Image header flags
#   0x08300000  headroom above the kernel's 35.6 MiB BSS-inclusive extent
#   0x0a000000  the boot FIT, as read off the card
#   0x0c000000  its 512-byte header
KERNEL_LOAD_ADDR = 0x02000000
FIT_LOAD_ADDR = 0x0A000000
HDR_LOAD_ADDR = 0x0C000000


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
# device tree reading — enough of it to take the vendor FIT apart


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
            if stack:
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
    # `stack[0]` is a sentinel; the tree's own root node is the unnamed child.
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
    if "data-position" in props:                       # absolute, what the vendor uses
        off = struct.unpack(">I", props["data-position"])[0]
    else:                                              # relative to the end of the tree
        total = struct.unpack(">I", fit[4:8])[0]
        off = ((total + 3) & ~3) + struct.unpack(">I", props["data-offset"])[0]
    return fit[off:off + size]


# --------------------------------------------------------------------------
# compression


def compress_kernel(raw: bytes, how: str) -> bytes:
    """Compress the vendor kernel for a FIT `compression` property.

    Unlike the vendor U-Boot's Android path, which sniffs the payload for a
    magic it recognises, a FIT declares its compression — so zstd is reachable
    here and is the reason this path exists at all (docs/01-boot-budget.md).
    """
    if how == "none":
        return raw
    if how == "gzip":
        return gzip.compress(raw, 9, mtime=0)
    if how == "lz4":
        return rk.compress_kernel(raw, "lz4")
    if how != "zstd":
        raise ValueError(f"unknown compression {how}")
    try:
        from compression import zstd                   # Python 3.14+
        return zstd.compress(raw, level=19)
    except ImportError:
        pass
    if shutil.which("zstd") is None:
        sys.exit("mkfit: --compress zstd needs Python 3.14+ or the `zstd` CLI "
                 "(brew install zstd)")
    with tempfile.TemporaryDirectory() as td:
        src, dst = f"{td}/k", f"{td}/k.zst"
        with open(src, "wb") as fh:
            fh.write(raw)
        subprocess.run(["zstd", "-19", "-T0", "-q", "-f", "-o", dst, src], check=True)
        return open(dst, "rb").read()


def decompress_kernel(blob: bytes, how: str) -> bytes:
    """Inverse of compress_kernel, used to prove the round-trip before writing."""
    if how == "none":
        return blob
    if how in ("gzip", "lz4"):
        return rk.decompress_kernel(blob)
    try:
        from compression import zstd
        return zstd.decompress(blob)
    except ImportError:
        pass
    with tempfile.TemporaryDirectory() as td:
        src, dst = f"{td}/k.zst", f"{td}/k"
        with open(src, "wb") as fh:
            fh.write(blob)
        subprocess.run(["zstd", "-d", "-q", "-f", "-o", dst, src], check=True)
        return open(dst, "rb").read()


# --------------------------------------------------------------------------
# mkfit.py uboot

# Carried from the vendor image node to ours, in this order. `load` is rewritten
# for U-Boot itself and copied for everything else; `entry` the vendor omits.
CARRY_PROPS = ("description", "type", "arch", "os", "compression", "load", "entry")


def cmd_uboot(a) -> int:
    vendor = open(a.vendor_fit, "rb").read()
    uboot = open(a.uboot_bin, "rb").read()
    tree = parse_fdt(vendor)
    images = tree["nodes"]["images"]["nodes"]
    configs = tree["nodes"]["configurations"]
    default = as_string(configs["props"]["default"])
    conf = configs["nodes"][default]["props"]

    firmware = as_string(conf["firmware"])
    loadables = as_stringlist(conf["loadables"])
    fdt_name = as_string(conf["fdt"]) if "fdt" in conf else None

    if uboot[:4] == b"\x7fELF":
        sys.exit("mkfit: expected u-boot.bin, got an ELF — pass the raw binary")

    drop = {"optee"} if a.drop_optee else set()
    order = [n for n in images if n not in drop]
    loadables = [n for n in loadables if n not in drop]

    print(f"vendor FIT     {a.vendor_fit}")
    print(f"  config       {default!r}: firmware={firmware} "
          f"loadables={' '.join(loadables)} fdt={fdt_name}")

    payloads: "list[tuple[str, bytes, dict]]" = []
    for name in order:
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
        return build_fdt(root)

    # Two passes: every value written between them is a fixed-width cell, so the
    # tree that carries the real offsets is the same length as the probe.
    probe = compose([0] * len(payloads), 0)
    cursor = FIT_DATA_START
    positions = []
    for _name, data, _props in payloads:
        positions.append(cursor)
        cursor = (cursor + len(data) + SECTOR - 1) // SECTOR * SECTOR
    if len(probe) > FIT_DATA_START:
        sys.exit(f"mkfit: the tree is {len(probe)} bytes, past the first payload "
                 f"at {FIT_DATA_START}")
    blob = compose(positions, cursor)
    if len(blob) != len(probe):
        sys.exit("mkfit: tree length moved between passes — refusing")

    out = bytearray(cursor)
    out[0:len(blob)] = blob
    for (name, data, _props), pos in zip(payloads, positions):
        out[pos:pos + len(data)] = data
        print(f"  {name:8s} {len(data):>9} bytes @ 0x{pos:06x}"
              f"{'   <- ours' if name == 'uboot' else ''}")

    with open(a.out, "wb") as fh:
        fh.write(out)
    print(f"  wrote {a.out}  ({len(out)} bytes)")

    verify(bytes(out), {"uboot": uboot},
           {n: image_data(vendor, images[n]) for n in order if n != "uboot"})
    print(f"  verified: sha256 per image, U-Boot at 0x{a.uboot_load:x}, "
          f"{len(order) - 1} vendor payload(s) byte-identical")
    return 0


def verify(fit: bytes, expect: "dict[str, bytes]", vendor_same: "dict[str, bytes]") -> None:
    """Re-read a written FIT and check every hash and payload."""
    tree = parse_fdt(fit)
    images = tree["nodes"]["images"]["nodes"]
    for name, image in images.items():
        data = image_data(fit, image)
        stored = image["nodes"]["hash"]["props"]["value"]
        assert hashlib.sha256(data).digest() == stored, f"{name}: sha256 mismatch"
        if name in expect:
            assert data == expect[name], f"{name}: payload is not what we wrote"
        if name in vendor_same:
            assert data == vendor_same[name], f"{name}: vendor payload changed"


# --------------------------------------------------------------------------
# mkfit.py boot


def cmd_boot(a) -> int:
    boot, res, dtb = rk.load(a.bootimg)
    print(f"vendor boot image {a.bootimg}")

    off, length = rk.fdt_find_bootargs(dtb)
    old = dtb[off:off + length].split(b"\0")[0].decode()
    new = rk.rewrite_root(old, a.root, a.rootfstype, a.drop, a.append)
    dtb = rk.set_bootargs(dtb, new)
    if a.led_trigger:
        dtb = rk.set_prop_string(dtb, "work", "linux,default-trigger", a.led_trigger)
    print(f"  rk-kernel.dtb  {len(dtb)} bytes")
    print(f"      old: {old}")
    print(f"      new: {new}")

    raw = boot.kernel
    # The arm64 Image header's image_size covers the BSS the kernel clears past
    # the end of the file, so it — not len(raw) — is what must fit below the
    # address U-Boot parks the compressed FIT at.
    image_size = struct.unpack_from("<Q", raw, 16)[0]
    if a.kernel_load % 0x200000:
        sys.exit(f"mkfit: kernel load 0x{a.kernel_load:x} is not 2 MiB-aligned")
    if a.kernel_load + image_size > FIT_LOAD_ADDR:
        sys.exit(f"mkfit: the kernel occupies 0x{a.kernel_load:x}.."
                 f"0x{a.kernel_load + image_size:x}, over the FIT at "
                 f"0x{FIT_LOAD_ADDR:x}")

    payload = compress_kernel(raw, a.compress)
    if a.compress != "none":
        print(f"  kernel: {a.compress} {len(raw)} -> {len(payload)} bytes "
              f"({100 * len(payload) / len(raw):.0f}%)")
        assert decompress_kernel(payload, a.compress) == raw, \
            "compressed kernel does not round-trip to the vendor image — refusing"

    root = Node("")
    root.string("description", "BaseOS my355")
    root.u32("#address-cells", 1)
    node_images = root.node("images")
    kernel = node_images.node("kernel")
    kernel.string("description", "vendor Linux 5.10.160")
    kernel.string("type", "kernel")
    kernel.string("os", "linux")
    kernel.string("arch", "arm64")
    kernel.string("compression", a.compress)
    kernel.u32("load", a.kernel_load)
    kernel.u32("entry", a.kernel_load)
    kernel.raw("data", payload)
    # The command line rides in the device tree, not in U-Boot. fdt_chosen()
    # rewrites /chosen/bootargs only when the `bootargs` environment variable is
    # set, and our build leaves it unset — so this is what the kernel gets, and
    # repointing root= for an A/B slot is a rebuild of this FIT alone.
    fdt = node_images.node("fdt")
    fdt.string("description", "rk-kernel.dtb, bootargs repointed at the card")
    fdt.string("type", "flat_dt")
    fdt.string("arch", "arm64")
    fdt.string("compression", "none")
    fdt.raw("data", dtb)
    # No hash nodes on purpose. U-Boot treats them as optional and verifying
    # sha256 over the whole kernel is exactly the kind of work this path exists
    # to delete; the SPL's hash check upstream still covers U-Boot itself.
    node_conf = root.node("configurations")
    node_conf.string("default", "conf")
    one = node_conf.node("conf")
    one.string("description", "BaseOS my355")
    one.string("kernel", "kernel")
    one.string("fdt", "fdt")

    blob = build_fdt(root)
    blob += b"\0" * (-len(blob) % SECTOR)
    sectors = len(blob) // SECTOR

    header = bytearray(SECTOR)
    struct.pack_into("<8sIII", header, 0, BOOT_HDR_MAGIC, sectors, len(blob),
                     BOOT_HDR_VERSION)
    with open(a.out, "wb") as fh:
        fh.write(bytes(header) + blob)
    print(f"  FIT: {len(blob)} bytes ({sectors} sectors), header + payload "
          f"= {SECTOR + len(blob)} bytes")
    print(f"  wrote {a.out}")

    check = parse_fdt(blob)
    got = check["nodes"]["images"]["nodes"]
    assert decompress_kernel(image_data(blob, got["kernel"]), a.compress) == raw, \
        "kernel does not round-trip out of the written FIT — refusing"
    back = image_data(blob, got["fdt"])
    boff, blen = rk.fdt_find_bootargs(back)
    line = back[boff:boff + blen].split(b"\0")[0].decode().strip()
    assert line == new.strip(), "bootargs read back wrong"
    assert f"root={a.root}" in line, "root= was not repointed"
    print("  verified: kernel round-trips to the vendor image, bootargs read back")
    return 0


# --------------------------------------------------------------------------


def cmd_verify_uboot(a) -> int:
    """Check a built `uboot` FIT against the card layout about to be written.

    CONFIG_BOOTCOMMAND names one sector and three addresses, all baked in at
    build time. If the layout or this file's DRAM map has moved since, U-Boot
    reads the wrong place — and on a device with no console the only symptom is
    a card that does not boot.
    """
    import json
    meta = json.load(open(a.meta))
    blob = open(a.itb, "rb").read()
    problems = []
    got = hashlib.sha256(blob).hexdigest()
    if got != meta.get("sha256"):
        problems.append(f"{a.itb} is {got[:16]}…, built as {meta.get('sha256', '?')[:16]}…")
    if meta.get("boot_start") != a.boot_start:
        problems.append(f"built to read sector {meta.get('boot_start')}, "
                        f"the card puts the payload at {a.boot_start}")
    for key, want in (("kernel_addr", KERNEL_LOAD_ADDR),
                      ("fit_addr", FIT_LOAD_ADDR),
                      ("hdr_addr", HDR_LOAD_ADDR)):
        if int(meta.get(key, "0"), 0) != want:
            problems.append(f"{key} is {meta.get(key)} in the build, 0x{want:x} here")
    if problems:
        for line in problems:
            print(f"  stale U-Boot build: {line}", file=sys.stderr)
        print("  rebuild it: ./build-uboot.sh", file=sys.stderr)
        return 1
    print(f"  {meta.get('banner', a.itb)}")
    print(f"  bootcmd: {meta.get('bootcmd')}")
    return 0


def cmd_addresses(a) -> int:
    """The single source of truth build-uboot.sh builds CONFIG_BOOTCOMMAND from."""
    print(f"MY355_KERNEL_ADDR={KERNEL_LOAD_ADDR:08x}")
    print(f"MY355_FIT_ADDR={FIT_LOAD_ADDR:08x}")
    print(f"MY355_HDR_ADDR={HDR_LOAD_ADDR:08x}")
    print(f"MY355_HDR_COUNT_OFF={8:x}")
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
        data = image_data(blob, image)
        bits = [f"{len(data)} bytes"]
        if "load" in props:
            bits.append(f"load 0x{struct.unpack('>I', props['load'])[0]:x}")
        if "compression" in props:
            bits.append(as_string(props["compression"]))
        print(f"  {name:10s} {', '.join(bits)}")
    configs = tree["nodes"]["configurations"]
    for name, one in configs["nodes"].items():
        for key, value in one["props"].items():
            if key in ("firmware", "loadables", "fdt", "kernel"):
                print(f"  {name}/{key}: {' '.join(as_stringlist(value))}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("uboot", help="FIT for the card's `uboot` partition")
    p.add_argument("vendor_fit", help="stock U-Boot FIT (prepared/uboot.img)")
    p.add_argument("uboot_bin", help="our mainline u-boot.bin")
    p.add_argument("out")
    p.add_argument("--uboot-load", type=lambda s: int(s, 0), required=True,
                   help="CONFIG_TEXT_BASE of the build")
    p.add_argument("--drop-optee", action="store_true",
                   help="leave OP-TEE out (not required — docs/09-uboot.md)")
    p.set_defaults(func=cmd_uboot)

    p = sub.add_parser("boot", help="FIT for the card's `boot` partition")
    p.add_argument("bootimg", help="stock Android boot image (prepared/boot.img)")
    p.add_argument("out")
    p.add_argument("--root", required=True)
    p.add_argument("--rootfstype")
    p.add_argument("--drop", action="append", default=[])
    p.add_argument("--append")
    p.add_argument("--led-trigger")
    p.add_argument("--compress", default="zstd",
                   choices=["none", "gzip", "lz4", "zstd"])
    p.add_argument("--kernel-load", type=lambda s: int(s, 0), default=KERNEL_LOAD_ADDR,
                   help="2 MiB-aligned, per the arm64 Image header flags")
    p.set_defaults(func=cmd_boot)

    p = sub.add_parser("addresses", help="emit the DRAM map as shell variables")
    p.set_defaults(func=cmd_addresses)

    p = sub.add_parser("verify-uboot", help="check a built FIT against this layout")
    p.add_argument("meta", help="work/my355/uboot-mainline.json")
    p.add_argument("itb", help="work/my355/uboot-mainline.itb")
    p.add_argument("--boot-start", type=int, required=True)
    p.set_defaults(func=cmd_verify_uboot)

    p = sub.add_parser("info", help="describe a FIT written by this tool")
    p.add_argument("fit")
    p.set_defaults(func=cmd_info)

    a = ap.parse_args()
    return a.func(a)


if __name__ == "__main__":
    raise SystemExit(main())
