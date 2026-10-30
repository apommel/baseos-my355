#!/bin/sh
# Compose the bootable BaseOS SD card image for my355 (Miyoo Flip).
#
# The Flip's boot chain lives in internal SPI NAND, so the card supplies only
# what that chain reaches for — a U-Boot FIT in a GPT partition named `uboot`,
# and the kernel FIT that U-Boot boots from one named `boot` — plus the rootfs.
#
# This requires a preloader with a working /pinctrl in mtd5; see docs/boot-chain.md.
#
# Inputs, from the other build steps:
#   uboot-mainline.itb   ./build-uboot.sh
#   kernel/              ./build-kernel.sh: Image, the device tree, kernel.json
#   rootfs.tar           ./build-rootfs.sh, with the same kernel's modules
#
# Usage: ./build-image.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"

WORK="$HERE/work/my355"
OUT="$WORK/baseos-my355.img"
ROOTFS_TAR="$WORK/rootfs.tar"
UBOOT_IMG="$WORK/uboot-mainline.itb"
BOOT_IMG="$WORK/boot-fit.img"

[ -f "$UBOOT_IMG" ] && [ -f "$WORK/uboot-mainline.json" ] || {
  echo "missing $UBOOT_IMG (run ./build-uboot.sh)" >&2; exit 1; }
# Its boot script bakes in mkfit.py's DRAM map and header layout.
python3 "$HERE/tools/mkfit.py" verify-uboot "$WORK/uboot-mainline.json" "$UBOOT_IMG"

[ -f "$WORK/kernel/kernel.json" ] || { echo "missing $WORK/kernel (run ./build-kernel.sh)" >&2; exit 1; }
[ -f "$ROOTFS_TAR" ] || { echo "missing $ROOTFS_TAR (run ./build-rootfs.sh)" >&2; exit 1; }
KREL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernelrelease"])' "$WORK/kernel/kernel.json")"
# The rootfs carries the modules for one kernel release; booting another loses the GPU.
tar -tf "$ROOTFS_TAR" | grep -qE "^(\./)?usr/lib/modules/$KREL/modules\.dep$" || {
  echo "$ROOTFS_TAR has no modules for $KREL (run ./build-rootfs.sh)" >&2; exit 1; }

# tools/mkgpt.py is the single source of truth for the sector layout and
# for which partition root= must name.
eval "$(python3 "$HERE/tools/mkgpt.py" --shell)"

# The preloader installer stock picks up off the card, on data: the only
# filesystem here stock can mount (docs/boot-chain.md).
FWIMG="$WORK/miyoo355_fw.img"
python3 "$HERE/tools/preloader-installer/mkfwimg.py" "$FWIMG" >/dev/null

# In Alpine so the zstd encoder comes pinned with the release rather than from
# whatever the host has installed. The command line is the device tree's own.
echo "== packing the kernel ($KREL) and device tree as a FIT =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work -v "$HERE/tools":/tools:ro \
  alpine:3.20 sh -euc '
  apk add -q python3 zstd
  python3 /tools/mkfit.py "$@"' sh \
  boot /work/kernel/Image /work/kernel/rk3566-miyoo-flip.dtb "/work/$(basename "$BOOT_IMG")" \
  --release "$KREL" --root "$MY355_ROOT_DEV" --slot-sectors "$MY355_BOOT_SLOT_SECTORS"

# Both go in an A/B slot, and an update writes a whole slot, so overflowing one
# would corrupt the reserved half rather than just this partition.
for pair in "uboot:$UBOOT_IMG:$MY355_UBOOT_SLOT_SECTORS" \
            "boot:$BOOT_IMG:$MY355_BOOT_SLOT_SECTORS"; do
  name="${pair%%:*}"; rest="${pair#*:}"; file="${rest%:*}"; room=$(( ${rest##*:} * 512 ))
  bytes=$(wc -c < "$file")
  [ "$bytes" -le "$room" ] || {
    echo "$name image is $bytes bytes; the slot holds $room" >&2
    exit 1
  }
done

echo "== composing $OUT =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work -v "$HERE/tools":/tools:ro \
  -e OUT_NAME="$(basename "$OUT")" \
  -e UBOOT_IMG="${UBOOT_IMG#"$WORK"/}" -e BOOT_IMG="${BOOT_IMG#"$WORK"/}" \
  -e UBOOT_START="$MY355_UBOOT_START" -e BOOT_START="$MY355_BOOT_START" \
  -e ROOTFS_START="$MY355_ROOTFS_START" -e SLOT_SECTORS="$MY355_ROOTFS_SLOT_SECTORS" \
  -e DATA_START="$MY355_DATA_START" -e DATA_SECTORS="$MY355_DATA_SECTORS" \
  -e PRIMARY_START="$MY355_PRIMARY_START" -e PRIMARY_SECTORS="$MY355_PRIMARY_SECTORS" \
  alpine:3.20 sh -euc '
  apk add -q e2fsprogs e2fsprogs-extra erofs-utils exfatprogs python3 sgdisk

  OUT="/work/$OUT_NAME"
  rm -f "$OUT"; : > "$OUT"
  python3 /tools/mkgpt.py "$OUT"

  dd if="/work/$UBOOT_IMG" of="$OUT" bs=512 seek="$UBOOT_START" conv=notrunc status=none
  dd if="/work/$BOOT_IMG"  of="$OUT" bs=512 seek="$BOOT_START"  conv=notrunc status=none

  # EROFS, lz4hc in 16 KiB clusters: half the bytes off the card, decoded fast
  # enough to keep up with page faults; larger clusters do not (docs/rootfs.md).
  R=/tmp/r; rm -rf "$R"; mkdir "$R"
  tar -xf /work/rootfs.tar -C "$R"
  mkfs.erofs -zlz4hc,12 -C16384 -L rootfs /tmp/rootfs.img "$R" >/dev/null
  [ "$(wc -c < /tmp/rootfs.img)" -le $((SLOT_SECTORS * 512)) ] || {
    echo "rootfs image does not fit its slot" >&2; exit 1; }
  dd if=/tmp/rootfs.img of="$OUT" bs=512 seek="$ROOTFS_START" conv=notrunc status=none

  # The reserved half of each region stays zeroed: the first update writes it.

  # Stock 5.10 has no orphan_file (5.15+), and reading the card from stock in
  # the left slot is how a failed boot is debugged (docs/diagnostics.md).
  EXT4_OPTS="^orphan_file"

  D=/tmp/d; rm -rf "$D"; mkdir "$D"; cp /work/miyoo355_fw.img "$D/"
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L data -d "$D" \
    -E offset=$((DATA_START * 512)) "$OUT" $((DATA_SECTORS / 8))

  # Empty: first boot reformats it at full size.
  truncate -s $(((PRIMARY_SECTORS - 2048) * 512)) /tmp/primary.img
  mkfs.exfat -L BASEOS /tmp/primary.img >/dev/null
  dd if=/tmp/primary.img of="$OUT" bs=512 seek="$PRIMARY_START" conv=notrunc status=none

  echo "-- verification --"
  sgdisk -v "$OUT" | tail -3
  dd if="$OUT" of=/tmp/rootfs.img bs=512 skip="$ROOTFS_START" count="$SLOT_SECTORS" status=none
  fsck.erofs --extract /tmp/rootfs.img >/dev/null && echo "  rootfs erofs OK"
  dd if="$OUT" of=/tmp/data.img bs=512 skip="$DATA_START" count="$DATA_SECTORS" status=none
  e2fsck -fn /tmp/data.img >/dev/null && echo "  data ext4 OK"
  fsck.exfat -n /tmp/primary.img >/dev/null && echo "  primary exfat OK"
  debugfs -R "stat /miyoo355_fw.img" "$OUT?offset=$((DATA_START * 512))" >/dev/null 2>&1 &&
    echo "  preloader installer on data"
'
python3 "$HERE/tools/mkfit.py" info "$BOOT_IMG"
echo "image: $OUT ($KREL)"
