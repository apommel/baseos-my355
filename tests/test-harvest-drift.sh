#!/bin/sh
# Offline test for the stale-harvest check in source_manifest.py: source.json
# pins the tar's hash, so after a harvest.list edit only the path check can tell
# that the tar is out of date. Host Python only; no container, no device.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "== harvest drift =="
python3 - "$HERE" <<'PY'
import json, os, subprocess, sys, tempfile

here = sys.argv[1]
sys.path.insert(0, os.path.join(here, "tools"))
from prepare_stock import harvest
from source_manifest import read_list, sha256_of

tmp = tempfile.mkdtemp()
root, prepared = os.path.join(tmp, "stock"), os.path.join(tmp, "prepared")
for p in ("usr/lib/libc.so.6", "usr/lib/libz.so.1", "usr/bin/curl",
          "usr/share/zoneinfo/posix/UTC", "usr/share/zoneinfo/right/UTC"):
    os.makedirs(os.path.dirname(os.path.join(root, p)), exist_ok=True)
    open(os.path.join(root, p), "w").write(p)
os.makedirs(prepared)
for name in ("uboot.img", "boot.img"):
    open(os.path.join(prepared, name), "wb").write(name.encode())

BASE = "/usr/lib/libc.so.6\n/usr/bin/curl\n/usr/share/zoneinfo\n!/usr/share/zoneinfo/right\n"
list_path = os.path.join(tmp, "harvest.list")


def prepare(text):
    """What prepare-stock.sh does: harvest from the list, pin it in source.json."""
    open(list_path, "w").write(text)
    tar = os.path.join(prepared, "stock-harvest.tar")
    include, exclude = read_list(list_path)
    harvest(root, include, tar, exclude)
    source = {"target": "my355"}
    for key, name in (("uboot", "uboot.img"), ("boot", "boot.img"),
                      ("harvest", "stock-harvest.tar")):
        path = os.path.join(prepared, name)
        source[key] = {"size": os.path.getsize(path), "sha256": sha256_of(path)}
    json.dump(source, open(os.path.join(prepared, "source.json"), "w"))


def verify(text):
    open(list_path, "w").write(text)
    r = subprocess.run([sys.executable, os.path.join(here, "tools", "source_manifest.py"),
                        "verify", os.path.join(prepared, "source.json"), prepared,
                        "--quiet", "--harvest-list", list_path],
                       capture_output=True, text=True)
    return r.returncode, r.stderr


def expect_fail(text, want, why):
    code, err = verify(text)
    if code == 0 or want not in err:
        sys.exit(f"{why}: exit {code}, stderr:\n{err}")


prepare(BASE)
code, err = verify(BASE)
if code:
    sys.exit(f"fresh harvest rejected:\n{err}")

expect_fail(BASE + "/usr/lib/libz.so.1\n",
            "not harvested: /usr/lib/libz.so.1", "a path added to the list")
expect_fail(BASE.replace("/usr/bin/curl\n", ""),
            "not listed:    /usr/bin/curl", "a path removed from the list")
code, err = verify(BASE.replace("/usr/share/zoneinfo\n!/usr/share/zoneinfo/right\n", ""))
if err.count("not listed:") != 1:
    sys.exit(f"a removed directory should be one line, not one per file:\n{err}")
expect_fail(BASE + "!/usr/share/zoneinfo/posix\n",
            "not listed:    /usr/share/zoneinfo/posix", "a new exclusion")

# Re-preparing is the fix the error names, and it clears the check.
prepare(BASE + "/usr/lib/libz.so.1\n")
code, err = verify(BASE + "/usr/lib/libz.so.1\n")
if code:
    sys.exit(f"re-prepared harvest rejected:\n{err}")
print("  PASS a harvest older than its list fails in both directions, and re-preparing clears it")
PY
