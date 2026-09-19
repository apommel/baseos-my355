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

`setargs` rewrites that line, raises the boot slot's UHS ceiling, replaces the
logo and stores the kernel gzipped. The kernel itself is never modified: the
build asserts that what it writes decompresses to the vendor bytes.

The resource image around it is rebuilt rather than patched, which frees the
logo from having to match the vendor's exact byte count and lets the whole
resource stay small enough for U-Boot's loader (see RESOURCE_SAFE_BYTES).

Usage:
    rkbootimg.py info    BOOTIMG
    rkbootimg.py extract BOOTIMG OUTDIR
    rkbootimg.py setargs BOOTIMG OUT --root /dev/mmcblk1p3 --rootfstype ext4
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import os
import shutil
import struct
import subprocess
import sys

PAGE_DEFAULT = 2048
# Largest resource image observed to boot on hardware. 943 616 bytes hangs this
# U-Boot before display init; 465 408 boots. The exact threshold is unmeasured.
RESOURCE_SAFE_BYTES = 465408
# SD slot 0 — the boot card, `mmcblk1` in Linux, the right-hand slot next to the
# power button. Slot 1 (dwmmc@fe2c0000) names the same vqmmc-supply, but its pins
# are on vccio4 = fixed 3.3 V, so UHS there hangs the card (tried 2026-09-16).
SD_SLOT0_NODE = "dwmmc@fe2b0000"

RES_MAGIC = b"RSCE"
RES_BLOCK = 512
RES_NAME_LEN = 256
FDT_MAGIC = b"\xd0\x0d\xfe\xed"
GZIP_MAGIC = b"\x1f\x8b"


def compress_kernel(raw: bytes) -> bytes:
    """Store the kernel gzipped, which is the big pre-kernel lever.

    U-Boot reads every byte of the payload off the card, so 4.96 s raw becomes
    2.86 s gzipped. libdeflate -12 is the same deflate format U-Boot's inflater
    already takes and 486 KB smaller than zlib -9; build-image.sh runs this in
    Alpine, which pins the encoder. (lz4 also boots, and was measured 0.17 s
    slower because the frame is 2.5 MiB larger — see docs/history.md.)
    """
    # -n: no name or mtime, so the bytes reproduce.
    cmd = ["libdeflate-gzip", "-12", "-n", "-c"]
    if shutil.which(cmd[0]) is None:
        sys.exit("rkbootimg: --compress-kernel gzip needs the `libdeflate-gzip` CLI "
                 "(brew install libdeflate, or apk add libdeflate-utils)")
    return subprocess.run(cmd, input=raw, stdout=subprocess.PIPE, check=True).stdout


def decompress_kernel(blob: bytes) -> bytes:
    """Inverse of compress_kernel, used to prove the round-trip before writing."""
    if blob[:2] != GZIP_MAGIC:
        raise ValueError("unrecognised compressed kernel")
    return gzip.decompress(blob)


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

    def compute_id(self) -> bytes:
        """SHA1 over kernel|size|ramdisk|size|second|size, as mkbootimg defines it.

        U-Boot verifies this before booting ("ANDROID: Hash OK"). Editing any
        payload without refreshing it makes boot_android refuse the image —
        while the *resource* image is still read earlier and unverified, so a
        replaced logo appears and then nothing boots.
        """
        h = hashlib.sha1()
        for payload in (self.kernel, self.ramdisk, self.second):
            h.update(payload)
            h.update(struct.pack("<I", len(payload)))
        return h.digest()

    @property
    def stored_id(self) -> bytes:
        return self.blob[576:576 + 20]

    def rebuild(self, second: bytes, kernel: bytes | None = None) -> bytes:
        """Repack with a new `second` and/or kernel, refreshing sizes and the id."""
        page = self.page_size
        kernel = self.kernel if kernel is None else kernel
        header = bytearray(self.blob[:page])
        struct.pack_into("<I", header, 8, len(kernel))          # kernel_size field
        struct.pack_into("<I", header, 8 + 16, len(second))     # second_size field
        out = bytearray(header)
        out += kernel + b"\0" * (_pad(len(kernel), page) - len(kernel))
        out += self.ramdisk + b"\0" * (_pad(self.ramdisk_size, page) - self.ramdisk_size)
        out += second + b"\0" * (_pad(len(second), page) - len(second))
        out[576:576 + 20] = BootImage(bytes(out)).compute_id()
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
        lets the whole resource stay under RESOURCE_SAFE_BYTES.
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


# --- flattened device tree ---------------------------------------------------
# One walker serves every reader below; the two writers both grow the struct
# block and hand it back to _fdt_rebuild.

def _fdt_header(dtb: bytes) -> tuple[int, int, int, int]:
    if dtb[:4] != FDT_MAGIC:
        raise ValueError("not a device tree blob")
    off_struct, off_strings = struct.unpack(">II", dtb[8:16])
    size_strings, size_struct = struct.unpack(">II", dtb[32:40])
    return off_struct, off_strings, size_strings, size_struct


def fdt_walk(dtb: bytes):
    """Yield the tree in file order.

    ("node", path, offset just past the name) for FDT_BEGIN_NODE, and
    ("prop", path, name, value offset, value length) for FDT_PROP.
    """
    off_struct, off_strings, size_strings, size_struct = _fdt_header(dtb)
    strings = dtb[off_strings:off_strings + size_strings]
    p, end, path = off_struct, off_struct + size_struct, []
    while p < end:
        tok = struct.unpack(">I", dtb[p:p + 4])[0]
        p += 4
        if tok == 1:                                  # FDT_BEGIN_NODE
            e = dtb.index(b"\0", p)
            path.append(dtb[p:e].decode() or "/")
            p = (e + 1 + 3) & ~3
            yield "node", tuple(path), p
        elif tok == 2:                                # FDT_END_NODE
            path.pop()
        elif tok == 3:                                # FDT_PROP
            length, nameoff = struct.unpack(">II", dtb[p:p + 8])
            p += 8
            name_end = strings.index(b"\0", nameoff)
            yield "prop", tuple(path), strings[nameoff:name_end].decode(), p, length
            p = (p + length + 3) & ~3
        elif tok == 9:                                # FDT_END
            break


def _fdt_is(path: tuple, node: str) -> bool:
    """`node` names the path's last component, or with slashes its last few:
    `port@1` alone is ambiguous where every encoder has one."""
    parts = tuple(node.split("/"))
    return path[-len(parts):] == parts


def fdt_find_prop(dtb: bytes, node: str, prop: str) -> tuple[int, int]:
    """Return (offset, length) of `prop`'s value in the first node named `node`."""
    for event in fdt_walk(dtb):
        if event[0] == "prop" and _fdt_is(event[1], node) and event[2] == prop:
            return event[3], event[4]
    raise KeyError(f"{node}/{prop} not found")


def fdt_node_props(dtb: bytes, node: str) -> "dict[str, bytes]":
    """Every property of the first node named `node`, as name -> raw value."""
    target, props = None, {}
    for event in fdt_walk(dtb):
        kind, path = event[0], event[1]
        if target is None:
            if kind == "node" and _fdt_is(path, node):
                target = path
            continue
        if path[:len(target)] != target:              # left the node
            break
        if kind == "prop" and path == target:
            props[event[2]] = dtb[event[3]:event[3] + event[4]]
    if target is None:
        raise KeyError(node)
    return props


def _fdt_require_dtc_layout(dtb: bytes) -> None:
    off_struct, off_strings, _size_strings, size_struct = _fdt_header(dtb)
    if off_strings < off_struct + size_struct:
        raise ValueError("FDT strings block does not follow the struct block; "
                         "this rewriter assumes dtc's layout")


def _fdt_rebuild(dtb: bytes, body: bytes, strings: bytes) -> bytes:
    """Reassemble around a new struct block, correcting the header's offsets."""
    off_struct = struct.unpack(">I", dtb[8:12])[0]
    out = bytearray(dtb[:off_struct] + body + strings)
    struct.pack_into(">I", out, 4, len(out))                 # totalsize
    struct.pack_into(">I", out, 12, off_struct + len(body))  # off_dt_strings
    struct.pack_into(">I", out, 32, len(strings))            # size_dt_strings
    struct.pack_into(">I", out, 36, len(body))               # size_dt_struct
    return bytes(out)


def _fdt_intern(strings: bytearray, name: str) -> int:
    """Offset of `name` in the strings block, appending it if absent."""
    encoded = name.encode() + b"\0"
    # Reuse an existing string only on a whole-entry match; a suffix match
    # (e.g. "sdr50" inside "sd-uhs-sdr50") would name the wrong property.
    if strings.startswith(encoded):
        return 0
    at = strings.find(b"\0" + encoded)
    if at >= 0:
        return at + 1
    strings += encoded
    return len(strings) - len(encoded)


def fdt_add_props(dtb: bytes, node: str,
                  props: "list[tuple[str, bytes]]") -> bytes:
    """Insert properties into the first node named `node`, growing the FDT.

    A property that does not exist yet has no length to reuse, so this relays
    out the blob: the new FDT_PROP tokens go at the head of the node's property
    list (the spec requires properties before subnodes, and right after
    FDT_BEGIN_NODE always satisfies that), their names are appended to the
    strings block, and the header's offsets and sizes are corrected.

    Properties already present are skipped rather than duplicated, so this is
    idempotent.
    """
    _fdt_require_dtc_layout(dtb)
    off_struct, off_strings, size_strings, size_struct = _fdt_header(dtb)

    existing = fdt_node_props(dtb, node)
    todo = [(n, v) for n, v in props if n not in existing]
    if not todo:
        return dtb

    # Just past this node's FDT_BEGIN_NODE.
    insert_at = next(e[2] for e in fdt_walk(dtb)
                     if e[0] == "node" and _fdt_is(e[1], node))

    strings = bytearray(dtb[off_strings:off_strings + size_strings])
    tokens = bytearray()
    for name, value in todo:
        tokens += struct.pack(">III", 3, len(value), _fdt_intern(strings, name))
        tokens += value + b"\0" * ((-len(value)) % 4)

    body = (dtb[off_struct:insert_at] + bytes(tokens)
            + dtb[insert_at:off_struct + size_struct])
    out = _fdt_rebuild(dtb, body, bytes(strings))

    # Read it back rather than trust the arithmetic: a mislaid offset here is a
    # card that hangs before any output exists to debug it.
    check = fdt_node_props(out, node)
    for name, value in props:
        if check.get(name) != value:
            raise ValueError(f"{node}/{name}: not readable after insertion")
    for name, value in existing.items():
        if check.get(name) != value:
            raise ValueError(f"{node}/{name}: damaged by insertion")
    return out


def fdt_add_subnode(dtb: bytes, parent: str, name: str,
                    props: "list[tuple[str, bytes]]") -> bytes:
    """Append a child node to the first node named `parent`, growing the FDT.

    The child goes just before the parent's FDT_END_NODE, which is valid
    whatever the parent holds: properties precede subnodes, and this is after
    both. A child of that name already present is left alone.
    """
    _fdt_require_dtc_layout(dtb)
    off_struct, off_strings, size_strings, size_struct = _fdt_header(dtb)
    try:
        fdt_node_props(dtb, name)
        return dtb
    except KeyError:
        pass

    # fdt_walk does not report FDT_END_NODE, so track depth here.
    p, end, depth, want, insert_at = off_struct, off_struct + size_struct, 0, None, None
    while p < end and insert_at is None:
        tok = struct.unpack(">I", dtb[p:p + 4])[0]
        if tok == 1:
            e = dtb.index(b"\0", p + 4)
            depth += 1
            if want is None and (dtb[p + 4:e].decode() or "/") == parent:
                want = depth
            p = (e + 1 + 3) & ~3
        elif tok == 2:
            if depth == want:
                insert_at = p
            depth -= 1
            p += 4
        elif tok == 3:
            length = struct.unpack(">I", dtb[p + 4:p + 8])[0]
            p = (p + 12 + length + 3) & ~3
        elif tok == 9:
            break
        else:                                         # FDT_NOP
            p += 4
    if insert_at is None:
        raise KeyError(parent)

    strings = bytearray(dtb[off_strings:off_strings + size_strings])
    encoded = name.encode() + b"\0"
    tokens = bytearray(struct.pack(">I", 1) + encoded + b"\0" * ((-len(encoded)) % 4))
    for pname, value in props:
        tokens += struct.pack(">III", 3, len(value), _fdt_intern(strings, pname))
        tokens += value + b"\0" * ((-len(value)) % 4)
    tokens += struct.pack(">I", 2)

    body = (dtb[off_struct:insert_at] + bytes(tokens)
            + dtb[insert_at:off_struct + size_struct])
    out = _fdt_rebuild(dtb, body, bytes(strings))

    check = fdt_node_props(out, name)
    for pname, value in props:
        if check.get(pname) != value:
            raise ValueError(f"{name}/{pname}: not readable after insertion")
    if fdt_node_props(out, parent) != fdt_node_props(dtb, parent):
        raise ValueError(f"{parent}: damaged by insertion")
    return out


# OP-TEE, resident for the life of the system: BL31 runs it as BL32. The vendor
# U-Boot carves it out of the /memory banks it writes; mainline U-Boot knows
# nothing about it, so on that path the reservation has to be in the tree.
OPTEE_BASE = 0x08400000
OPTEE_SIZE = 0x01000000


def add_optee_reservation(dtb: bytes) -> bytes:
    """Reserve OP-TEE's 16 MiB as no-map, for the mainline U-Boot path only.

    Without it the kernel allocates over live secure firmware and dies just
    after `Starting kernel ...` — the 2026-08-24 failure (docs/uboot.md).
    """
    cells = fdt_node_props(dtb, "reserved-memory")
    if (struct.unpack(">I", cells["#address-cells"])[0],
            struct.unpack(">I", cells["#size-cells"])[0]) != (2, 2):
        raise ValueError("/reserved-memory is not 2/2 cells; the reg below assumes it")
    reg = struct.pack(">QQ", OPTEE_BASE, OPTEE_SIZE)
    return fdt_add_subnode(dtb, "reserved-memory", f"optee@{OPTEE_BASE:x}",
                           [("reg", reg), ("no-map", b"")])


# VOP2 windows by physical id (the vendor dt-bindings). On the RK3566, Cluster1,
# Esmart1 and Smart1 are mirrors: they only work once their main window is
# enabled, so the panel needs the mains. The vendor U-Boot writes this split
# into the kernel's tree at boot (rk3568_assign_plane_mask: the first display
# that cannot be hot-plugged is the main one); without it the kernel falls back
# to a default that gives the DSI port the mirrors, and NextUI draws nothing.
VOP2_NODE = "vop@fe040000"
VOP2_MAIN = (0x15, 4)      # Cluster0, Esmart0, Smart0; primary Smart0
VOP2_MIRROR = (0x2a, 5)    # Cluster1, Esmart1, Smart1; primary Smart1
VOP2_DISPLAYS = (("dsi@fe060000", VOP2_MAIN), ("hdmi@fe0a0000", VOP2_MIRROR))


def vop2_port_of(dtb: bytes, encoder: str) -> str:
    """The VOP port the encoder's enabled endpoint is wired to, e.g. `port@1`."""
    nodes: "dict[tuple, dict[str, bytes]]" = {}
    for event in fdt_walk(dtb):
        if event[0] == "prop":
            nodes.setdefault(event[1], {})[event[2]] = dtb[event[3]:event[3] + event[4]]
    remotes = {props["remote-endpoint"] for path, props in nodes.items()
               if encoder in path and "remote-endpoint" in props
               and props.get("status", b"okay\0") == b"okay\0"}
    ports = {path[-2] for path, props in nodes.items()
             if VOP2_NODE in path and props.get("phandle") in remotes}
    if len(ports) != 1:
        raise ValueError(f"{encoder}: wired to VOP ports {sorted(ports)}, expected one")
    return ports.pop()


def set_vop2_plane_masks(dtb: bytes) -> bytes:
    """Assign VOP2 windows as the vendor U-Boot does, for the mainline path only."""
    seen = set()
    for encoder, (mask, primary) in VOP2_DISPLAYS:
        port = vop2_port_of(dtb, encoder)
        if port in seen:
            raise ValueError(f"{encoder} shares {port} with another display")
        seen.add(port)
        node = f"{VOP2_NODE}/ports/{port}"
        if "rockchip,plane-mask" in fdt_node_props(dtb, node):
            raise ValueError(f"{node} already assigns planes; this would not override it")
        dtb = fdt_add_props(dtb, node, [
            ("rockchip,plane-mask", struct.pack(">I", mask)),
            ("rockchip,primary-plane", struct.pack(">I", primary)),
        ])
    return dtb


PANEL_NODE = "dsi@fe060000/panel@0"
# Vendor value -> ours. reset/init only wait out power-on, which U-Boot now
# does ~1.8 s earlier (no reset line here); enable holds the backlight, which
# rcS lights. The init sequence's own 250 + 32 ms stay.
PANEL_DELAYS = {"reset-delay-ms": (160, 0), "init-delay-ms": (200, 20),
                "enable-delay-ms": (200, 0)}


def set_panel_delays(dtb: bytes) -> bytes:
    """Shorten the panel's power-up waits, for the mainline path only."""
    props = fdt_node_props(dtb, PANEL_NODE)
    if "reset-gpios" in props:
        raise ValueError(f"{PANEL_NODE} has a reset line; reset-delay-ms is real")
    out = bytearray(dtb)
    for prop, (vendor, ours) in PANEL_DELAYS.items():
        off, length = fdt_find_prop(dtb, PANEL_NODE, prop)
        got = struct.unpack(">I", dtb[off:off + length])[0]
        if length != 4 or got != vendor:
            raise ValueError(f"{PANEL_NODE}/{prop} is {got}, expected {vendor}")
        struct.pack_into(">I", out, off, ours)
    return bytes(out)


# UHS modes the RK3566 sdmmc controller can drive, in ascending order, with the
# bus clock each one implies. Anything above SDR25 also needs max-frequency to
# allow it and the I/O rail to be switchable to 1.8 V — both asserted below.
SD_UHS_MODES = {
    "sdr50": (["sd-uhs-sdr50"], 100_000_000),
    "sdr104": (["sd-uhs-sdr50", "sd-uhs-sdr104"], 150_000_000),
}


def set_sd_uhs(dtb: bytes, node: str, mode: str) -> bytes:
    """Raise the SD slot's ceiling from the vendor's SDR25 to `mode`.

    The vendor DTB declares sd-uhs-sdr12/sdr25 and stops, which pins the bus at
    50 MHz — ~22 MB/s measured, against a controller that does SDR104. The rail
    is already where UHS needs it (the card negotiates SDR25, so vccio_sd is at
    1.8 V), which makes this a clock change rather than a voltage change.
    """
    flags, needed = SD_UHS_MODES[mode]
    props = fdt_node_props(dtb, node)
    if "vqmmc-supply" not in props:
        raise ValueError(f"{node}: no vqmmc-supply; UHS needs a switchable "
                         "I/O rail and this slot has none")
    maxfreq = struct.unpack(">I", props["max-frequency"])[0]
    if maxfreq < needed:
        raise ValueError(f"{node}: max-frequency is {maxfreq}, but {mode} "
                         f"needs {needed}; raising it is a separate decision")
    return fdt_add_props(dtb, node, [(f, b"") for f in flags])


def set_bootargs(dtb: bytes, new_args: str) -> bytes:
    """Rewrite /chosen/bootargs: in place, space-padded, when it fits; grown otherwise.

    The vendor value holds 100 bytes. Growing relays out the struct block the way
    fdt_add_props does, which the SDR104 flags already prove this U-Boot accepts.
    """
    off, length = fdt_find_prop(dtb, "chosen", "bootargs")
    budget = length - 1                               # value includes its NUL
    if len(new_args) <= budget:
        out = bytearray(dtb)
        out[off:off + length] = new_args.ljust(budget).encode() + b"\0"
        return bytes(out)

    _fdt_require_dtc_layout(dtb)
    off_struct, off_strings, size_strings, size_struct = _fdt_header(dtb)
    value = new_args.encode() + b"\0"
    old_end = off + length + ((-length) % 4)
    body = (dtb[off_struct:off - 8]
            + struct.pack(">I", len(value)) + dtb[off - 4:off]   # len, nameoff
            + value + b"\0" * ((-len(value)) % 4)
            + dtb[old_end:off_struct + size_struct])
    out = _fdt_rebuild(dtb, body, dtb[off_strings:off_strings + size_strings])

    # Read it back: a mislaid offset is a card that hangs with nothing to debug.
    noff, nlen = fdt_find_prop(out, "chosen", "bootargs")
    if out[noff:noff + nlen] != value:
        raise ValueError("bootargs not readable after growing the FDT")
    return out


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


def load(path: str) -> tuple[BootImage, ResourceImage]:
    boot = BootImage(open(path, "rb").read())
    return boot, ResourceImage(boot.second)


def bootargs_of(res: ResourceImage, off: int, size: int) -> str:
    blob = res.blob[off:off + size]
    boff, blen = fdt_find_prop(blob, "chosen", "bootargs")
    return blob[boff:boff + blen].split(b"\0")[0].decode()


def cmd_info(a) -> int:
    boot, res = load(a.bootimg)
    print(f"boot image     {a.bootimg}")
    print(f"  page size    {boot.page_size}")
    print(f"  kernel       {boot.kernel_size} bytes @ {boot.kernel_off} "
          f"(load 0x{boot.kernel_addr:x})  sha256 {hashlib.sha256(boot.kernel).hexdigest()[:16]}…")
    print(f"  ramdisk      {boot.ramdisk_size} bytes")
    print(f"  second       {boot.second_size} bytes @ {boot.second_off}  (RSCE, {res.count} entries)")
    for name, _off, size in res.entries():
        print(f"      {name:22s} {size:>8} bytes")
    ok = boot.compute_id() == boot.stored_id
    print(f"  image id     {boot.stored_id.hex()}  ({'valid' if ok else 'STALE'})")
    for name, off, size in res.entries():
        if not name.startswith("rk-kernel.dtb"):
            continue
        cur = bootargs_of(res, off, size)
        _boff, blen = fdt_find_prop(res.blob[off:off + size], "chosen", "bootargs")
        print(f"  bootargs     {name}: {len(cur)} chars used of {blen - 1} available")
        print(f"      {cur}")
    return 0


def cmd_extract(a) -> int:
    boot, res = load(a.bootimg)
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
    boot, res = load(a.bootimg)

    # Every rk-kernel.dtb* variant gets the same treatment. U-Boot selects the
    # `.hdmi` one when Miyoo's g_miyoo_use_hdmi is set, and a variant left
    # carrying the stock root=/dev/mtdblock3 would not boot BaseOS at all.
    expected: "dict[str, str]" = {}

    def patch(name: str, blob: bytes) -> bytes:
        off, length = fdt_find_prop(blob, "chosen", "bootargs")
        old = blob[off:off + length].split(b"\0")[0].decode()
        new = rewrite_root(old, a.root, a.rootfstype, a.drop, a.append)
        expected[name] = new
        out = set_bootargs(blob, new)
        if a.sd_uhs != "off":
            out = set_sd_uhs(out, SD_SLOT0_NODE, a.sd_uhs)
        print(f"  {name}")
        print(f"      old: {old}")
        print(f"      new: {new}")
        return out

    # Rebuild the resource image rather than patch it in place. The logo is then
    # free to be any size, and the whole resource can be kept small enough for
    # U-Boot's loader (see ResourceImage.build).
    logo = open(a.logo, "rb").read() if a.logo else None
    entries = []
    for name, off, size in res.entries():
        data = res.blob[off:off + size]
        if name.startswith("rk-kernel.dtb"):
            entries.append((name, patch(name, data)))
        elif logo is not None and name in ("logo.bmp", "logo_kernel.bmp"):
            entries.append((name, logo))
        else:
            entries.append((name, data))
    if a.sd_uhs != "off":
        added = ", ".join(SD_UHS_MODES[a.sd_uhs][0])
        print(f"  sd: {SD_SLOT0_NODE} += {added} "
              f"(vendor stops at SDR25 = 50 MHz; slot 1 left alone)")

    second = ResourceImage.build(entries)
    print(f"  resource: rebuilt, {boot.second_size} -> {len(second)} bytes "
          f"({len(second) // 512} blocks)")
    if len(second) > RESOURCE_SAFE_BYTES:
        print(f"  WARNING: resource is {len(second)} bytes; {RESOURCE_SAFE_BYTES} is the "
              f"largest size observed to boot. U-Boot hangs before display init above "
              f"some threshold between that and 943616.", file=sys.stderr)
    kernel = None
    if a.compress_kernel != "none":
        if boot.kernel[:2] == GZIP_MAGIC:
            print("  kernel: already compressed, left alone")
        else:
            kernel = compress_kernel(boot.kernel)
            print(f"  kernel: gzip {boot.kernel_size} -> {len(kernel)} bytes "
                  f"({100 * len(kernel) / boot.kernel_size:.0f}%)")
    out = boot.rebuild(second, kernel)
    with open(a.out, "wb") as fh:
        fh.write(out)
    print(f"  wrote {a.out}  ({len(out)} bytes)")

    verify_boot, verify_res = load(a.out)
    expected_kernel = kernel if kernel is not None else boot.kernel
    assert verify_boot.kernel == expected_kernel, "kernel payload changed — refusing"
    if kernel is not None:
        assert decompress_kernel(verify_boot.kernel) == boot.kernel, \
            "compressed kernel does not round-trip to the vendor image — refusing"
    assert [n for n, _, _ in verify_res.entries()] == [n for n, _ in entries], \
        "resource entry set changed — refusing"
    assert verify_boot.compute_id() == verify_boot.stored_id, \
        "boot image id is stale — U-Boot would reject this"
    seen = 0
    for name, off, size in verify_res.entries():
        if not name.startswith("rk-kernel.dtb"):
            continue
        got = bootargs_of(verify_res, off, size).strip()
        assert got == expected[name].strip(), f"{name}: bootargs read back wrong"
        assert f"root={a.root}" in got, f"{name}: root= was not repointed"
        seen += 1
    assert seen, "no rk-kernel.dtb* found in the resource — refusing"
    print(f"  image id refreshed: {verify_boot.stored_id.hex()}")
    kind = "kernel round-trips to the vendor image" if kernel is not None \
           else "kernel byte-identical"
    print(f"  verified: {kind}, id valid, {seen} device tree(s) read back correctly")
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

    p = sub.add_parser("setargs", help="repoint root= and repack")
    p.add_argument("bootimg")
    p.add_argument("out")
    p.add_argument("--root", required=True, help="e.g. /dev/mmcblk1p3")
    p.add_argument("--rootfstype", default=None, help="e.g. ext4")
    p.add_argument("--drop", action="append", default=[],
                   metavar="PREFIX", help="remove tokens starting with PREFIX (repeatable)")
    p.add_argument("--append", default=None,
                   metavar="TOKENS", help='extra tokens, e.g. "console=tty0"')
    p.add_argument("--compress-kernel", choices=("none", "gzip"), default="none",
                   help="store the kernel gzipped so U-Boot reads far less off "
                        "the card; this U-Boot sniffs the format")
    p.add_argument("--logo", default=None, metavar="BMP",
                   help="replace logo.bmp/logo_kernel.bmp; any size, subject to "
                        "RESOURCE_SAFE_BYTES")
    p.add_argument("--sd-uhs", choices=("off", "sdr50", "sdr104"), default="off",
                   help="raise the boot slot's UHS ceiling above the vendor's "
                        "SDR25. The controller does SDR104 and max-frequency is "
                        "already 150 MHz; only the mode flags are missing")
    p.set_defaults(fn=cmd_setargs)

    a = ap.parse_args()
    try:
        return a.fn(a)
    except (ValueError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
