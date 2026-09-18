#!/usr/bin/env python3
"""Check work/my355/prepared/ against the source.json describing it.

    source_manifest.py verify SOURCE_JSON PREPARED_DIR [--quiet]
                              [--harvest-list PATH]

The trust anchor for both ways of getting those artifacts — deriving them from a
NAND dump, or restoring the published bundle. A bad restore then fails where a
bad prepare would.

The hashes alone cannot catch a harvest that predates manifest/harvest.list:
source.json still matches the old tar after the list changes. So the tar's paths
are checked against the list too.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tarfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ARTIFACTS = {"uboot": "uboot.img", "boot": "boot.img", "harvest": "stock-harvest.tar"}


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def read_list(path: str) -> tuple[list[str], list[str]]:
    """Returns (include, exclude). A leading "!" excludes a path from a
    directory listed above it — tzdata's right/ tree, for example."""
    include, exclude = [], []
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        (exclude if line.startswith("!") else include).append(line.lstrip("!").strip())
    return include, exclude


def under(path: str, roots: list[str]) -> bool:
    return any(path == r or path.startswith(r + "/") for r in roots)


def harvest_drift(tar_path: str, list_path: str) -> tuple[list[str], list[str]]:
    """(listed paths the tar lacks, tar paths the list no longer asks for).

    The tar holds exactly each listed path and its subtree, minus exclusions,
    so a list edit in either direction shows up here."""
    include, exclude = read_list(list_path)
    include = [p.strip("/") for p in include]
    exclude = [p.strip("/") for p in exclude]
    with tarfile.open(tar_path) as tar:
        members = {m.name.removeprefix("./").strip("/") for m in tar}
    missing = ["/" + p for p in include if p not in members]
    extra = []
    for m in sorted(m for m in members if not under(m, include) or under(m, exclude)):
        if not (extra and m.startswith(extra[-1] + "/")):   # one line per subtree
            extra.append(m)
    return missing, ["/" + m for m in extra]


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

    missing, extra = harvest_drift(os.path.join(a.prepared_dir, ARTIFACTS["harvest"]),
                                   a.harvest_list)
    if missing or extra:
        lines = [f"source_manifest: stock-harvest.tar does not match {a.harvest_list}"]
        lines += [f"  not harvested: {p}" for p in missing]
        lines += [f"  not listed:    {p}" for p in extra]
        lines.append("re-run ./prepare-stock.sh NAND_DIR; "
                     "a published bundle then needs ./cache-pack.sh")
        sys.exit("\n".join(lines))
    if not a.quiet:
        print(f"  ok  stock-harvest.tar matches {os.path.relpath(a.harvest_list, HERE)}")
        print(f"  verified (prepared_utc {source.get('prepared_utc', 'unknown')})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    v = sub.add_parser("verify")
    v.add_argument("source_json")
    v.add_argument("prepared_dir")
    v.add_argument("--quiet", action="store_true")
    v.add_argument("--harvest-list", default=os.path.join(HERE, "manifest", "harvest.list"))
    v.set_defaults(fn=cmd_verify)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
