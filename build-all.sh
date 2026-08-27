#!/bin/sh
# Build the release artifacts from prepared inputs.
# Usage: ./build-all.sh
#
# Produces work/my355/baseos-my355-<version>.img.zip, for a new card, and
# .bosupd, which updates one that is already running. Inputs come from
# fetch-prepared.sh or prepare-stock.sh; each step below runs standalone.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work/my355"

VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
[ -n "$VERSION" ] || { echo "VERSION is empty" >&2; exit 1; }
command -v zip >/dev/null 2>&1 || { echo "zip is required to package images" >&2; exit 1; }

# Up front, rather than part-way through a long build.
for artifact in source.json uboot.img boot.img stock-harvest.tar; do
  [ -f "$WORK/prepared/$artifact" ] || {
    echo "missing $WORK/prepared/$artifact — run ./fetch-prepared.sh" >&2
    exit 1
  }
done

"$HERE/build-rootfs.sh"
"$HERE/build-image.sh"
"$HERE/build-update.sh"

archive="$WORK/baseos-my355-$VERSION.img.zip"
rm -f "$archive"
# -j: bare baseos-my355.img inside. -X: no host metadata in a published file.
zip -q -j -X "$archive" "$WORK/baseos-my355.img"

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

echo
echo "=== release artifacts for $VERSION ==="
# The image is for a new card; the payload updates one that is already running.
for f in "$archive" "$WORK/baseos-my355-$VERSION.bosupd"; do
  printf "  %-40s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  printf "  %s\n" "$(sha256 "$f")"
done
