#!/bin/sh
# Compose the bootable BaseOS SD card image for my355 (Miyoo Flip).
#
# Nothing here is inherited from a vendor disk image: unlike the H700 port, the
# Flip's boot chain lives in internal SPI NAND. The card supplies only what that
# chain reaches for — a U-Boot FIT in a GPT partition named `uboot`, an Android
# boot image in one named `boot` — plus the BaseOS rootfs.
#
# This requires GammaLoader's preloader in mtd5; see docs/my355/02-sd-boot.md.
#
# Inputs come from ./prepare-stock-my355.sh, in work/my355/prepared:
#   uboot.img   stock Rockchip U-Boot FIT, used verbatim
#   boot.img    stock Android boot image; the kernel stays byte-for-byte
#               identical, only the DTB's bootargs and logo are rewritten
#
# Environment:
#   MY355_DIAG=1     bring-up aids: kernel-side LED heartbeat + panic=10
#                    (see docs/my355/07-bringup-and-diagnostics.md)
#
# Usage: ./build-image-my355.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

WORK="$HERE/work/my355"
PREPARED="$WORK/prepared"
OUT="$WORK/baseos-my355.img"
ROOTFS_TAR="$WORK/rootfs.tar"
UBOOT_SRC="$PREPARED/uboot.img"
BOOT_SRC="$PREPARED/boot.img"

for f in "$UBOOT_SRC" "$BOOT_SRC"; do
  [ -f "$f" ] || {
    echo "missing $f (run ./prepare-stock-my355.sh)" >&2
    exit 1
  }
done
[ -f "$ROOTFS_TAR" ] || { echo "missing $ROOTFS_TAR (run ./build-rootfs-my355.sh)" >&2; exit 1; }

mkdir -p "$WORK"

# tools/mkgpt_my355.py is the single source of truth for the sector layout and
# for which partition root= must name.
eval "$(python3 "$HERE/tools/mkgpt_my355.py" --shell)"

# The vendor command line uses all 100 available bytes and in-place FDT patching
# cannot grow it (tools/rkbootimg.py). `earlycon=` is dead weight on a unit with
# no UART attached, and dropping it makes room for what we do need:
#
#   init=/init   REQUIRED. For a disk root the kernel only tries /sbin/init,
#                /etc/init, /bin/init and /bin/sh — `/init` is the initramfs
#                convention. Without this the kernel execs /bin/sh, which waits
#                forever on a console that does not exist. H700 sets it too.
#   rw           init writes runtime state to the root filesystem.
# The vendor kernel is a raw 34.9 MiB arm64 Image and U-Boot reads every byte off
# the card each boot, so storing it compressed is the big pre-kernel lever:
# 4.96 s raw -> 3.14 s gzip -> 3.31 s lz4. gzip wins on size; both boot.
# MY355_COMPRESS_KERNEL = none | gzip | lz4 (docs/my355/01-boot-budget.md).
COMPRESS="${MY355_COMPRESS_KERNEL:-gzip}"     # none | gzip | lz4

DROP="earlycon="
APPEND="rw init=$MY355_INIT"
LED_TRIGGER=""

if [ "${MY355_DIAG:-0}" = "1" ]; then
  # panic=10 turns a silent hang into a visible reboot loop; the LED heartbeat
  # fires at gpio-leds probe, proving the kernel is alive before userspace runs.
  APPEND="$APPEND panic=10"
  LED_TRIGGER="heartbeat"
  echo "== diagnostics enabled (panic=10, LED heartbeat) =="
fi

# The BaseOS wordmark, cropped from the shared artwork so branding matches the
# H700 port. Size keeps the rebuilt resource image well under the largest one
# proven to boot (tools/rkbootimg.py, RESOURCE_SAFE_BYTES).
MY355_LOGO_SIZE="${MY355_LOGO_SIZE:-240x48}"
MY355_LOGO_ASSET="${MY355_LOGO_ASSET:-$HERE/assets/bootlogo.bmp}"
python3 "$HERE/tools/mkbootlogo_my355.py" "$MY355_LOGO_ASSET" \
  "$WORK/baseos-logo.bmp" --size "$MY355_LOGO_SIZE" --preview

echo "== repointing the vendor boot image at the card =="
python3 "$HERE/tools/rkbootimg.py" setargs "$BOOT_SRC" "$WORK/boot-sd.img" \
  --root "$MY355_ROOT_DEV" --rootfstype ext4 --logo "$WORK/baseos-logo.bmp" \
  --drop "$DROP" --append "$APPEND" \
  ${LED_TRIGGER:+--led-trigger "$LED_TRIGGER"} \
  --compress-kernel "$COMPRESS"

echo "== composing $OUT =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work -v "$HERE/tools":/tools:ro \
  -e OUT_NAME="$(basename "$OUT")" \
  -e UBOOT_START="$MY355_UBOOT_START" -e BOOT_START="$MY355_BOOT_START" \
  -e ROOTFS_START="$MY355_ROOTFS_START" -e SLOT_SECTORS="$MY355_SLOT_SECTORS" \
  -e DATA_START="$MY355_DATA_START" -e DATA_SECTORS="$MY355_DATA_SECTORS" \
  -e PRIMARY_START="$MY355_PRIMARY_START" -e PRIMARY_SECTORS="$MY355_PRIMARY_SECTORS" \
  alpine:3.20 sh -euc '
  apk add -q e2fsprogs e2fsprogs-extra dosfstools python3 sgdisk

  OUT="/work/$OUT_NAME"
  rm -f "$OUT"; : > "$OUT"
  python3 /tools/mkgpt_my355.py "$OUT"

  # The vendor chain: U-Boot verbatim, boot image with only the DTB rewritten.
  dd if=/work/prepared/uboot.img of="$OUT" bs=512 seek="$UBOOT_START" conv=notrunc status=none
  dd if=/work/boot-sd.img    of="$OUT" bs=512 seek="$BOOT_START"  conv=notrunc status=none

  # This kernel is 5.10.160. orphan_file needs 5.15+, so it must be off; the
  # other modern features are fine, unlike the H700 port and its 4.9 kernel.
  EXT4_OPTS="^orphan_file"

  R=/tmp/r; rm -rf "$R"; mkdir "$R"
  tar -xf /work/rootfs.tar -C "$R"
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L rootfs -d "$R" \
    -E offset=$((ROOTFS_START * 512)) "$OUT" $((SLOT_SECTORS / 8))

  # Slot B stays zeroed and unallocated: the first system update writes it.

  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L data \
    -E offset=$((DATA_START * 512)) "$OUT" $((DATA_SECTORS / 8))

  mkfs.vfat -F 32 -n BASEOS -S 512 --offset "$PRIMARY_START" \
    "$OUT" $(((PRIMARY_SECTORS - 2048) / 2)) >/dev/null 2>&1

  echo "-- verification --"
  sgdisk -v "$OUT" | tail -3
  dd if="$OUT" of=/tmp/p3.img bs=512 skip="$ROOTFS_START" count="$SLOT_SECTORS" status=none
  e2fsck -fn /tmp/p3.img >/dev/null && echo "  rootfs (slot A) ext4 OK"
  dd if="$OUT" of=/tmp/p4.img bs=512 skip="$DATA_START" count="$DATA_SECTORS" status=none
  e2fsck -fn /tmp/p4.img >/dev/null && echo "  data ext4 OK"
'
python3 "$HERE/tools/rkbootimg.py" info "$WORK/boot-sd.img" | grep -E "image id|bootargs" 
echo "image: $OUT"
