#!/usr/bin/env python3
"""Check work/my355/prepared/ against the source.json describing it.

    source_manifest.py verify SOURCE_JSON PREPARED_DIR

The trust anchor for both ways of getting those artifacts — deriving them from a
NAND dump, or restoring the published bundle. A bad restore then fails where a
bad prepare would.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

ARTIFACTS = {"uboot": "uboot.img", "boot": "boot.img", "harvest": "stock-harvest.tar"}


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_verify(a) -> int:
    try:
        with open(a.source_json) as fh:
            source = json.load(fh)
    except (OSError, ValueError) as exc:
        sys.exit(f"source_manifest: cannot read {a.source_json}: {exc}")

    if source.get("target") != "my355":
        sys.exit(f"source_manifest: {a.source_json} is not a my355 manifest")

    for key, name in ARTIFACTS.items():
        want = source.get(key)
        if not isinstance(want, dict) or {"sha256", "size"} - want.keys():
            sys.exit(f"source_manifest: {a.source_json} has no {key} entry")

        path = os.path.join(a.prepared_dir, name)
        if not os.path.isfile(path):
            sys.exit(f"source_manifest: missing {path}")

        size = os.path.getsize(path)
        if size != want["size"]:
            sys.exit(f"source_manifest: {name} is {size} bytes, "
                     f"manifest says {want['size']}")

        got = sha256_of(path)
        if got != want["sha256"]:
            sys.exit(f"source_manifest: {name} SHA-256 mismatch\n"
                     f"  expected {want['sha256']}\n  got      {got}")
        if not a.quiet:
            print(f"  ok  {name}  {size} bytes")

    if not a.quiet:
        print(f"  verified (prepared_utc {source.get('prepared_utc', 'unknown')})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verify")
    v.add_argument("source_json")
    v.add_argument("prepared_dir")
    v.add_argument("--quiet", action="store_true")
    v.set_defaults(fn=cmd_verify)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
