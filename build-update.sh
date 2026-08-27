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
BUILD="$(git -C "$HERE" describe --always --dirty 2>/dev/null || echo unknown)"
OUT="$WORK/baseos-my355-$VERSION.bosupd"

python3 "$HERE/tools/mkupdate.py" "$IMAGE" my355 "$VERSION" "$BUILD" "$OUT"

echo
echo "Copy $(basename "$OUT") to the root of the card and power on."
