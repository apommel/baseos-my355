#!/usr/bin/env python3
"""Pack the preloader installer as a miyoo355_fw.img stock will pick up off a card.

Header at sector 0, the script stock runs at sector 1, the payload tar at sector 16.
Mechanism and rationale: docs/02-sd-boot.md.

    mkfwimg.py OUT.img [--version STR]
"""

import argparse
import io
import pathlib
import tarfile

SECTOR = 512
SCRIPT_SECTORS = 8          # miyoo_fw_update reads exactly this much
PAYLOAD_SECTOR = 16
HERE = pathlib.Path(__file__).parent
PAYLOAD = ("install.sh", "patch-preloader.sh", "fdtpatch.awk")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--version", default="baseos-preloader-1")
    args = ap.parse_args()

    header = f"model:miyoo355\nversion:{args.version}\n".encode()
    if len(header) > SECTOR:
        raise SystemExit("header does not fit in one sector")

    script = (HERE / "bootstrap.sh").read_bytes()
    if len(script) > SCRIPT_SECTORS * SECTOR:
        raise SystemExit(f"bootstrap.sh is {len(script)} bytes, over the 4 KiB stock reads")

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for name in PAYLOAD:
            info = tar.gettarinfo(HERE / name, arcname=name)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            with open(HERE / name, "rb") as f:
                tar.addfile(info, f)

    img = bytearray(header.ljust(SECTOR, b"\0"))
    img += script.ljust(SCRIPT_SECTORS * SECTOR, b"\0")
    img = img.ljust(PAYLOAD_SECTOR * SECTOR, b"\0")
    img += buf.getvalue()

    pathlib.Path(args.out).write_bytes(bytes(img))
    print(f"wrote {args.out} ({len(img)} bytes, version {args.version})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
