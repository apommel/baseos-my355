#!/usr/bin/env python3
"""Build a BaseOS `.bosupd` update payload from a composed image.

The payload carries the `uboot`, `boot` and `rootfs` slots of a finished image,
each gzipped whole, plus a manifest. Applying it writes those exact bytes into
the inactive half of each region and flips the GPT, so an updated card ends up
byte-identical to a freshly flashed one — same filesystems, same hashes.

Integrity is a SHA-256 per region, printed here so the rootfs one can be
published next to the download. There is no signature: a signing key would be a
single point of failure for every update, and these images carry no secrets.

Usage: mkupdate.py IMAGE TARGET VERSION BUILD OUTPUT
"""
import gzip
import hashlib
import io
import struct
import sys
import tarfile
from pathlib import Path

SECTOR = 512
CHUNK = 4 * 1024 * 1024
REGIONS = ("uboot", "boot", "rootfs")


def die(msg):
    sys.exit(f"mkupdate: {msg}")


def extents(image: Path) -> dict:
    """Return {name: (first_lba, sectors)} for every partition in the image."""
    with image.open("rb") as handle:
        handle.seek(SECTOR)
        header = handle.read(SECTOR)
        if header[:8] != b"EFI PART":
            die("no primary GPT in the image")
        entries_lba = struct.unpack_from("<Q", header, 72)[0]
        count, size = struct.unpack_from("<II", header, 80)
        handle.seek(entries_lba * SECTOR)
        table = handle.read(count * size)

    found = {}
    for i in range(count):
        entry = table[i * size:(i + 1) * size]
        name = entry[56:128].decode("utf-16-le").rstrip("\0")
        if name:
            start, end = struct.unpack_from("<QQ", entry, 32)
            found[name] = (start, end - start + 1)
    return found


def pack(image: Path, start: int, sectors: int, stamps: dict) -> tuple[str, bytes]:
    """Hash and gzip one slot, noting any stamp seen along the way."""
    digest = hashlib.sha256()
    compressed = io.BytesIO()
    window = max(len(stamp) for stamp in stamps)
    tail = b""
    with image.open("rb") as handle, gzip.GzipFile(
        fileobj=compressed, mode="wb", compresslevel=6, mtime=0
    ) as gz:
        handle.seek(start * SECTOR)
        remaining = sectors * SECTOR
        while remaining:
            chunk = handle.read(min(CHUNK, remaining))
            if not chunk:
                die("the image is shorter than the partitions it declares")
            remaining -= len(chunk)
            digest.update(chunk)
            gz.write(chunk)
            haystack = tail + chunk
            for stamp in stamps:
                if stamp in haystack:
                    stamps[stamp] = True
            tail = chunk[-window:]
    return digest.hexdigest(), compressed.getvalue()


def main() -> int:
    if len(sys.argv) != 6:
        die("usage: mkupdate.py IMAGE TARGET VERSION BUILD OUTPUT")
    image, target, version, build, output = (
        Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], Path(sys.argv[5])
    )

    parts = extents(image)
    for name in (*REGIONS, "data", "primary"):
        if name not in parts:
            die(f"the image has no `{name}` partition")

    # Both stamps matter: a manifest claiming a version the filesystem does not
    # carry would make the card apply it, boot, still disagree about its own
    # version, and apply it again.
    stamps = {
        f"BASEOS_VERSION={version}".encode(): False,
        f"BASEOS_BUILD={build}".encode(): False,
    }

    members, fields = [], [
        ("format", "baseos-update/2"),
        ("target", target),
        ("version", version),
        ("build", build),
    ]
    for name in REGIONS:
        start, sectors = parts[name]
        sha, blob = pack(image, start, sectors, stamps)
        print(f"{name:7s} LBA {start}, {sectors} sectors -> {len(blob)} bytes  {sha}")
        fields += [(f"{name}-sectors", sectors), (f"{name}-sha256", sha)]
        members.append((f"{name}.img.gz", blob))

    for stamp, seen in stamps.items():
        if not seen:
            die(f"the image does not contain {stamp.decode()} — rebuild the rootfs first")

    manifest = "".join(f"{k}={v}\n" for k, v in fields).encode()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(output, "w", format=tarfile.USTAR_FORMAT) as archive:
        for name, blob in (("manifest", manifest), *members):
            info = tarfile.TarInfo(name)
            info.size = len(blob)
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            archive.addfile(info, io.BytesIO(blob))

    print(f"payload: {output} ({output.stat().st_size} bytes)")
    print(f"         {target} {version} ({build})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
