#!/usr/bin/env python3
"""Build the my355 (Miyoo Flip) SD card partition table from scratch.

Unlike the H700 port — which inherits the vendor GPT and edits it (upstream-h700/tools/mkgpt.py)
— the Flip's boot chain lives in internal SPI NAND, so a BaseOS card owns its
whole table. Three names are load-bearing:

    uboot    the SPL locates U-Boot by `part_get_info_by_name("uboot")`
             and reads the FIT from the partition's FIRST SECTOR. That SPL has no
             raw-sector fallback, so this entry must exist and must start at 16384.
    boot     stock U-Boot runs `boot_android mmc 1`, which resolves the Android
             boot image by this name.
    rootfs   named for humans only. What actually matters is its ENTRY NUMBER:
             `root=/dev/mmcblk1p3` is baked into rk-kernel.dtb at build time
             (tools/rkbootimg.py), so rootfs must stay entry 3.

Layout, mirroring the H700 A/B scheme (upstream-h700/docs/07-partition-layout-and-updates.md):

    1 uboot    8 MiB   @ sector 16384
    2 boot    40 MiB
    3 rootfs 512 MiB   slot A
      (gap)  512 MiB   slot B — the update target, deliberately NOT a partition
    4 data   128 MiB   ext4, persistent state, survives a slot flip
    5 primary  rest    FAT32, the only desktop-visible volume

Slot B is unallocated on purpose: it costs no visible partition and no desktop
OS offers to format it. Every entry except `primary` carries GPT attribute bits
62 and 63, so a desktop assigns exactly one drive letter for the whole card.

Unique GUIDs are derived deterministically from the partition name, so two
builds of the same layout produce byte-identical tables.

Usage:
    mkgpt.py IMAGE [--primary-sectors N]   write the table into IMAGE
    mkgpt.py --shell                       emit the layout as shell vars
"""

from __future__ import annotations

import argparse
import struct
import sys
import uuid
import zlib

SECTOR = 512
NUM_ENTRIES = 128
ENTRY_SIZE = 128
ENTRY_SECTORS = NUM_ENTRIES * ENTRY_SIZE // SECTOR          # 32
HIDDEN_ATTRIBUTES = 0xC000000000000000                       # bits 62 + 63

LINUX_FS = uuid.UUID("0fc63daf-8483-4772-8e79-3d69d8477de4")
MS_BASIC = uuid.UUID("ebd0a0a2-b9e5-4433-87c0-68b6b72699c7")
DISK_NS = uuid.UUID("6b1f2a2c-0d7e-5a3b-9c11-ba5e0feed001")

MIB = 1024 * 1024 // SECTOR                                  # sectors per MiB

UBOOT_START = 16384                                          # load-bearing
UBOOT_SECTORS = 8 * MIB
BOOT_SECTORS = 40 * MIB
SLOT_SECTORS = 512 * MIB
DATA_SECTORS = 128 * MIB
PRIMARY_SECTORS_DEFAULT = 64 * MIB                           # grown on first boot


def guid_for(name: str) -> uuid.UUID:
    return uuid.uuid5(DISK_NS, f"my355/{name}")


def layout(primary_sectors: int):
    """Return [(name, type_guid, first_lba, last_lba, attrs), ...] and the total."""
    boot_start = UBOOT_START + UBOOT_SECTORS
    rootfs_start = boot_start + BOOT_SECTORS
    slot_b_start = rootfs_start + SLOT_SECTORS                # unallocated
    data_start = slot_b_start + SLOT_SECTORS
    primary_start = data_start + DATA_SECTORS
    primary_end = primary_start + primary_sectors - 1
    total = primary_end + 1 + ENTRY_SECTORS + 1               # backup entries + header

    parts = [
        ("uboot",   LINUX_FS, UBOOT_START,   UBOOT_START + UBOOT_SECTORS - 1, HIDDEN_ATTRIBUTES),
        ("boot",    LINUX_FS, boot_start,    boot_start + BOOT_SECTORS - 1,   HIDDEN_ATTRIBUTES),
        ("rootfs",  LINUX_FS, rootfs_start,  rootfs_start + SLOT_SECTORS - 1, HIDDEN_ATTRIBUTES),
        ("data",    LINUX_FS, data_start,    data_start + DATA_SECTORS - 1,   HIDDEN_ATTRIBUTES),
        ("primary", MS_BASIC, primary_start, primary_end,                     0),
    ]
    return parts, total, slot_b_start


def build_entries(parts) -> bytes:
    table = bytearray(NUM_ENTRIES * ENTRY_SIZE)
    for i, (name, type_guid, first, last, attrs) in enumerate(parts):
        off = i * ENTRY_SIZE
        struct.pack_into("<16s16sQQQ", table, off,
                         type_guid.bytes_le, guid_for(name).bytes_le, first, last, attrs)
        encoded = name.encode("utf-16-le")
        table[off + 56:off + 56 + len(encoded)] = encoded
    return bytes(table)


def build_header(*, current_lba, backup_lba, first_usable, last_usable,
                 disk_guid, entries_lba, entries_crc) -> bytes:
    hdr = bytearray(92)
    struct.pack_into("<8sIIIIQQQQ16sQIII", hdr, 0,
                     b"EFI PART", 0x00010000, 92, 0, 0,
                     current_lba, backup_lba, first_usable, last_usable,
                     disk_guid.bytes_le, entries_lba, NUM_ENTRIES, ENTRY_SIZE, entries_crc)
    struct.pack_into("<I", hdr, 16, zlib.crc32(bytes(hdr)) & 0xFFFFFFFF)
    return bytes(hdr)


def protective_mbr(total: int) -> bytes:
    mbr = bytearray(SECTOR)
    mbr[446 + 4] = 0xEE
    struct.pack_into("<I", mbr, 446 + 8, 1)
    struct.pack_into("<I", mbr, 446 + 12, min(total - 1, 0xFFFFFFFF))
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("image", nargs="?")
    ap.add_argument("--primary-sectors", type=int, default=PRIMARY_SECTORS_DEFAULT)
    ap.add_argument("--print-only", action="store_true")
    ap.add_argument("--shell", action="store_true",
                    help="emit the layout as shell variables; this is the single "
                         "source of truth for build-image.sh")
    a = ap.parse_args()

    parts, total, slot_b = layout(a.primary_sectors)

    if a.shell:
        by_name = {name: (first, last) for name, _t, first, last, _a in parts}
        print(f"MY355_UBOOT_START={by_name['uboot'][0]}")
        print(f"MY355_BOOT_START={by_name['boot'][0]}")
        print(f"MY355_ROOTFS_START={by_name['rootfs'][0]}")
        print(f"MY355_SLOT_SECTORS={SLOT_SECTORS}")
        print(f"MY355_SLOT_B_START={slot_b}")
        print(f"MY355_DATA_START={by_name['data'][0]}")
        print(f"MY355_DATA_SECTORS={DATA_SECTORS}")
        print(f"MY355_PRIMARY_START={by_name['primary'][0]}")
        print(f"MY355_PRIMARY_SECTORS={a.primary_sectors}")
        print(f"MY355_TOTAL_SECTORS={total}")
        # rootfs is GPT entry 3; root= must name that number (see module docstring)
        print("MY355_ROOT_DEV=/dev/mmcblk1p3")
        print("MY355_INIT=/init")
        return 0

    first_usable = 2 + ENTRY_SECTORS
    last_usable = total - ENTRY_SECTORS - 2

    prev_end = first_usable - 1
    for name, _t, first, last, _a in parts:
        if first <= prev_end:
            sys.exit(f"mkgpt: {name} overlaps the previous region")
        prev_end = last
    if parts[-1][3] > last_usable:
        sys.exit("mkgpt: primary extends past the last usable LBA")

    print(f"  {'partition':10s} {'start':>10s} {'end':>10s} {'size':>10s}")
    for name, _t, first, last, _a in parts:
        print(f"  {name:10s} {first:>10d} {last:>10d} {(last-first+1)//MIB:>7d} MiB")
        if name == "rootfs":
            print(f"  {'(slot B)':10s} {slot_b:>10d} {slot_b+SLOT_SECTORS-1:>10d} "
                  f"{SLOT_SECTORS//MIB:>7d} MiB   unallocated — update target")
    print(f"  total {total} sectors ({total*SECTOR/1024/1024:.1f} MiB)")
    if a.print_only:
        return 0

    entries = build_entries(parts)
    entries_crc = zlib.crc32(entries) & 0xFFFFFFFF
    disk_guid = guid_for("__disk__")

    if not a.image:
        sys.exit("mkgpt: IMAGE is required unless --shell/--print-only")
    with open(a.image, "r+b") as f:
        f.truncate(total * SECTOR)
        f.seek(0)
        f.write(protective_mbr(total))
        f.write(build_header(current_lba=1, backup_lba=total - 1,
                             first_usable=first_usable, last_usable=last_usable,
                             disk_guid=disk_guid, entries_lba=2, entries_crc=entries_crc))
        f.seek(2 * SECTOR)
        f.write(entries)
        f.seek((total - 1 - ENTRY_SECTORS) * SECTOR)
        f.write(entries)
        f.seek((total - 1) * SECTOR)
        f.write(build_header(current_lba=total - 1, backup_lba=1,
                             first_usable=first_usable, last_usable=last_usable,
                             disk_guid=disk_guid, entries_lba=total - 1 - ENTRY_SECTORS,
                             entries_crc=entries_crc))
    print(f"  wrote GPT to {a.image}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
