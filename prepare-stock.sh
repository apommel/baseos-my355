#!/bin/sh
# Derive my355 build inputs from a NAND backup of a Miyoo Flip.
#
# Produces work/my355/prepared/{uboot.img, boot.img, stock-harvest.tar,
# source.json} — the same set fetch-prepared.sh restores from a published bundle.
# NAND_DIR holds mtd1-uboot.img, mtd2-boot.img and mtd3-rootfs.img, as
# docs/recovery.md describes taking them.
#
# boot.img must be PRISTINE stock: a unit whose bootlogo has been replaced
# carries a rewritten resource image, which is not what should be redistributed.
#
# Usage: ./prepare-stock.sh NAND_DIR
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"

NAND="${1:?usage: $0 NAND_DIR}"
OUT="$HERE/work/my355/prepared"
mkdir -p "$OUT"

# unsquashfs and a predictable Python live in the container, not on the host.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$NAND":/nand:ro -v "$OUT":/out -v "$HERE/tools":/tools:ro \
  -v "$HERE/manifest":/manifest:ro \
  alpine:3.20 sh -euc '
  apk add -q squashfs-tools python3
  python3 /tools/prepare_stock.py /nand /out \
    --harvest-list /manifest/harvest.list
  '

echo "prepared: $OUT"
