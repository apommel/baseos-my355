#!/bin/sh
# Build the release artifacts from prepared inputs.
# Usage: ./build-all.sh
#
# Produces work/my355/baseos-my355-<version>.img.zip, for a new card, and
# .bosupd, which updates one that is already running. Inputs come from
# fetch-prepared.sh or prepare-stock.sh; each step below runs standalone.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"
WORK="$HERE/work/my355"

VERSION="$(baseos_version)"
command -v zip >/dev/null 2>&1 || { echo "zip is required to package images" >&2; exit 1; }
# Up front, rather than part-way through a long build.
baseos_require_prepared "$WORK/prepared"
if [ "${MY355_UBOOT:-vendor}" = mainline ]; then
  python3 "$HERE/tools/mkfit.py" verify-uboot "$WORK/uboot-mainline.json" \
    "$WORK/uboot-mainline.itb" >/dev/null || {
    echo "run ./build-uboot.sh first (MY355_UBOOT=mainline)" >&2; exit 1; }
fi

"$HERE/build-rootfs.sh"
"$HERE/build-image.sh"
"$HERE/build-update.sh"

archive="$WORK/baseos-my355-$VERSION.img.zip"
rm -f "$archive"
# -j: bare baseos-my355.img inside. -X: no host metadata in a published file.
zip -q -j -X "$archive" "$WORK/baseos-my355.img"

echo
echo "=== release artifacts for $VERSION ==="
# The image is for a new card; the payload updates one that is already running.
for f in "$archive" "$WORK/baseos-my355-$VERSION.bosupd"; do
  printf "  %-40s %s\n" "$(basename "$f")" "$(du -h "$f" | cut -f1)"
  printf "  %s\n" "$(baseos_sha256 "$f")"
done
