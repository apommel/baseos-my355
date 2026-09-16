#!/bin/sh
# Build the .bosupd system-update payload from the composed image. Users copy
# the result onto their card; the next boot applies it to the reserved half of
# each region without touching their ROMs, saves or settings.
# Usage: ./build-update.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$HERE/work/my355"
IMAGE="$WORK/baseos-my355.img"
[ -f "$IMAGE" ] || { echo "missing $IMAGE (run ./build-image.sh)" >&2; exit 1; }

VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
# Stamped into the rootfs by build-rootfs.sh; the manifest must carry the same.
BUILD="$(cat "$WORK/build-id" 2>/dev/null)" || { echo "missing $WORK/build-id (run ./build-rootfs.sh)" >&2; exit 1; }
OUT="$WORK/baseos-my355-$VERSION.bosupd"

python3 "$HERE/tools/mkupdate.py" "$IMAGE" my355 "$VERSION" "$BUILD" "$OUT"

echo
echo "Copy $(basename "$OUT") to the root of the card and power on."
