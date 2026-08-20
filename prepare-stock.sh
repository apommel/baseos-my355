#!/bin/sh
# Derive my355 build inputs from a NAND backup of a Miyoo Flip.
#
# Produces work/my355/prepared/{uboot.img, boot.img, stock-harvest.tar, source.json}
# — the same shape the H700 path produces from a vendor disk image, and the set
# that would later ship as a release bundle (cf. fetch-prepared.sh).
#
# boot.img must be PRISTINE stock. A unit whose bootlogo has been replaced
# carries a rewritten resource image; pass --boot to point at a clean one.
#
# Usage: ./prepare-stock-my355.sh [NAND_DIR] [--boot PATH]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tools/docker-platform.sh"

NAND="${1:-$HOME/Development/miyoo-flip-nand-backup}"
[ "$#" -gt 0 ] && shift || true
OUT="$HERE/work/my355/prepared"
mkdir -p "$OUT"

# unsquashfs and a predictable Python live in the container, not on the host.
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$NAND":/nand:ro -v "$OUT":/out -v "$HERE/tools":/tools:ro \
  -v "$HERE/manifest":/manifest:ro \
  alpine:3.20 sh -euc '
  apk add -q squashfs-tools python3
  python3 /tools/prepare_stock_my355.py /nand /out \
    --harvest-list /manifest/harvest-my355.list "$@"
  ' -- "$@"

echo "prepared: $OUT"
