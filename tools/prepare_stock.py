#!/usr/bin/env python3
"""Derive my355 build inputs from a NAND backup of a Miyoo Flip.

The H700 port prepares its inputs from an 11.7 GB vendor disk image
(tools/prepare_stock.py). The Flip has no such image: its firmware lives in
internal SPI NAND, so the inputs come from a backup of that
(docs/my355/03-nand-backup-and-recovery.md).

Three artifacts are produced, mirroring the H700 shape:

    uboot.img          mtd1 verbatim — the Rockchip U-Boot FIT the SPL loads
    boot.img           mtd2 verbatim — the Android boot image (kernel + DTB)
    stock-harvest.tar  the allowlisted slice of mtd3's squashfs rootfs
    source.json        sizes, hashes and provenance for all three

`boot.img` must be **pristine stock**. A unit whose bootlogo has been replaced
carries a rewritten resource image — different logo geometry and a reordered
entry table — which still boots but is not what should be redistributed.
`--boot` takes an explicit path for that case.

Unlike the H700 source, mtd3 is **squashfs**, so it is unpacked with unsquashfs
rather than debugfs. It is unpacked to a container-local scratch directory, never
to a bind-mounted output path: the stock rootfs contains both /mnt/sdcard and
/mnt/SDCARD, which collide on a case-insensitive host filesystem such as macOS.

The harvest is verified, not assumed: every DT_NEEDED of every harvested ELF
must resolve inside the harvest, or preparation fails. That is the check that
turns an allowlist into a closure.

Usage:
    prepare_stock_my355.py NAND_DIR OUT_DIR [--boot PATH] [--harvest-list PATH]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import time

MTD1 = "mtd1-uboot.img"
MTD2 = "mtd2-boot.img"
MTD3 = "mtd3-rootfs.img"


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_list(path: str) -> list[str]:
    out = []
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if line:
            out.append(line)
    return out


def elf_needed(path: str) -> tuple[list[str], str | None]:
    """Return (DT_NEEDED names, soname) for an ELF, or ([], None) if not one."""
    with open(path, "rb") as fh:
        data = fh.read()
    if data[:4] != b"\x7fELF" or data[4] != 2:            # 64-bit ELF only
        return [], None
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    if not e_shoff:
        return [], None
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = \
            struct.unpack_from("<IIQQQQIIQQ", data, off)
        sections.append((name, typ, offset, size, link, entsize))
    dyn = next((s for s in sections if s[1] == 6), None)   # SHT_DYNAMIC
    if dyn is None:
        return [], None
    strtab = sections[dyn[4]]
    strs = data[strtab[2]:strtab[2] + strtab[3]]
    needed, soname = [], None
    off, end = dyn[2], dyn[2] + dyn[3]
    while off + 16 <= end:
        tag, val = struct.unpack_from("<qQ", data, off)
        off += 16
        if tag == 0:
            break
        if tag in (1, 14):                                # DT_NEEDED, DT_SONAME
            s = strs[val:strs.index(b"\0", val)].decode(errors="replace")
            if tag == 1:
                needed.append(s)
            else:
                soname = s
    return needed, soname


def unpack_rootfs(image: str, dest: str) -> None:
    if shutil.which("unsquashfs") is None:
        sys.exit("prepare_stock_my355: unsquashfs not found "
                 "(run this inside the build container, or `brew install squashfs`)")
    if os.path.isdir(dest):
        shutil.rmtree(dest)
    subprocess.run(["unsquashfs", "-q", "-n", "-d", dest, image],
                   check=True, stdout=subprocess.DEVNULL)


def harvest(root: str, paths: list[str], out_tar: str) -> tuple[list[str], list[str]]:
    """Tar the allowlisted paths, dereferencing symlinks. Returns (taken, missing)."""
    taken, missing = [], []
    with tarfile.open(out_tar, "w") as tar:
        for p in paths:
            src = os.path.join(root, p.lstrip("/"))
            if not os.path.exists(src):
                missing.append(p)
                continue
            real = os.path.realpath(src)
            tar.add(real, arcname=p.lstrip("/"), recursive=True)
            taken.append(p)
    return taken, missing


def verify_closure(tar_path: str, workdir: str) -> list[str]:
    """Every DT_NEEDED of every harvested ELF must resolve inside the harvest."""
    scratch = os.path.join(workdir, "closure-check")
    if os.path.isdir(scratch):
        shutil.rmtree(scratch)
    os.makedirs(scratch)
    with tarfile.open(tar_path) as tar:
        tar.extractall(scratch, filter="data")
    provided, wanted = set(), {}
    for dirpath, _dirs, files in os.walk(scratch):
        for name in files:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            try:
                needed, soname = elf_needed(full)
            except Exception:
                continue
            if soname:
                provided.add(soname)
            provided.add(name)
            for n in needed:
                wanted.setdefault(n, []).append(os.path.relpath(full, scratch))
    shutil.rmtree(scratch)
    return sorted(n for n in wanted if n not in provided)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("nand_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--boot", default=None,
                    help="pristine stock mtd2 image (default: NAND_DIR/mtd2-boot.img)")
    ap.add_argument("--harvest-list", default=None)
    a = ap.parse_args()

    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    harvest_list = a.harvest_list or os.path.join(here, "manifest", "harvest-my355.list")
    uboot_src = os.path.join(a.nand_dir, MTD1)
    boot_src = a.boot or os.path.join(a.nand_dir, MTD2)
    rootfs_src = os.path.join(a.nand_dir, MTD3)
    for p in (uboot_src, boot_src, rootfs_src, harvest_list):
        if not os.path.exists(p):
            sys.exit(f"prepare_stock_my355: missing {p}")

    os.makedirs(a.out_dir, exist_ok=True)
    uboot_out = os.path.join(a.out_dir, "uboot.img")
    boot_out = os.path.join(a.out_dir, "boot.img")
    tar_out = os.path.join(a.out_dir, "stock-harvest.tar")

    shutil.copyfile(uboot_src, uboot_out)
    shutil.copyfile(boot_src, boot_out)
    print(f"  uboot.img  {os.path.getsize(uboot_out)} bytes")
    print(f"  boot.img   {os.path.getsize(boot_out)} bytes  (from {os.path.basename(boot_src)})")

    scratch = tempfile.mkdtemp(prefix="my355-prepare-")
    stock_root = os.path.join(scratch, "stock-root")
    print(f"  unpacking {MTD3} (squashfs) …")
    unpack_rootfs(rootfs_src, stock_root)

    paths = read_list(harvest_list)
    taken, missing = harvest(stock_root, paths, tar_out)
    if missing:
        print("  MISSING from the stock rootfs:", file=sys.stderr)
        for m in missing:
            print(f"    {m}", file=sys.stderr)
        sys.exit("prepare_stock_my355: harvest list does not match this firmware")
    print(f"  stock-harvest.tar  {os.path.getsize(tar_out)} bytes, {len(taken)} paths")

    unresolved = verify_closure(tar_out, scratch)
    if unresolved:
        print("  UNRESOLVED shared library dependencies:", file=sys.stderr)
        for u in unresolved:
            print(f"    {u}", file=sys.stderr)
        sys.exit("prepare_stock_my355: harvest is not a closed set — add these to "
                 "manifest/harvest-my355.list")
    print("  closure verified: every DT_NEEDED resolves inside the harvest")

    source = {
        "schema": 1,
        "target": "my355",
        "model": "Miyoo Flip",
        "provenance": "nand-backup",
        "prepared_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "uboot": {"size": os.path.getsize(uboot_out), "sha256": sha256_of(uboot_out)},
        "boot": {"size": os.path.getsize(boot_out), "sha256": sha256_of(boot_out),
                 "source_filename": os.path.basename(boot_src)},
        "harvest": {"size": os.path.getsize(tar_out), "sha256": sha256_of(tar_out),
                    "paths": len(taken)},
        "source": {
            "mtd1": {"sha256": sha256_of(uboot_src)},
            "mtd3": {"sha256": sha256_of(rootfs_src)},
        },
    }
    shutil.rmtree(scratch, ignore_errors=True)

    with open(os.path.join(a.out_dir, "source.json"), "w") as fh:
        json.dump(source, fh, indent=2, sort_keys=True)
        fh.write("\n")
    print(f"  source.json written")
    return 0


if __name__ == "__main__":
    sys.exit(main())
