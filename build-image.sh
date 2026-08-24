#!/bin/sh
# Compose the bootable BaseOS SD card image for my355 (Miyoo Flip).
#
# Nothing here is inherited from a vendor disk image: unlike the H700 port, the
# Flip's boot chain lives in internal SPI NAND. The card supplies only what that
# chain reaches for — a U-Boot FIT in a GPT partition named `uboot`, an Android
# boot image in one named `boot` — plus the BaseOS rootfs.
#
# This requires a preloader with a working /pinctrl in mtd5; see docs/02-sd-boot.md.
#
# Inputs come from ./prepare-stock.sh, in work/my355/prepared:
#   uboot.img   stock Rockchip U-Boot FIT, used verbatim
#   boot.img    stock Android boot image; the kernel stays byte-for-byte
#               identical, only the DTB's bootargs and logo are rewritten
#
# Environment:
#   MY355_UBOOT=vendor|mainline   which bootloader the card carries (default
#                    vendor). `mainline` needs ./build-uboot.sh first.
#   MY355_DIAG=1     bring-up aids: kernel-side LED heartbeat + panic=10
#                    (see docs/07-bringup-and-diagnostics.md)
#
# Usage: ./build-image.sh
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

# Which bootloader the card carries.
#
#   vendor    the stock Rockchip 2017.09 FIT verbatim, booting the vendor
#             Android boot image. What every released BaseOS card ships with.
#   mainline  our own U-Boot from ./build-uboot.sh, booting a FIT from a fixed
#             sector. It deletes the vendor bootloader's 1.21 s of
#             initialisation and is the only path zstd is reachable from — and
#             it draws no boot logo, because mainline U-Boot has no VOP2 driver
#             for this SoC. See docs/09-uboot.md.
#
# The default stays `vendor` until `mainline` is measured on hardware: this
# script builds the artifact people flash.
UBOOT="${MY355_UBOOT:-vendor}"
case "$UBOOT" in
  vendor|mainline) ;;
  *) echo "MY355_UBOOT must be vendor or mainline, not $UBOOT" >&2; exit 2 ;;
esac

for f in "$PREPARED/source.json" "$UBOOT_SRC" "$BOOT_SRC"; do
  [ -f "$f" ] || {
    echo "missing $f" >&2
    echo "run ./fetch-prepared.sh, or ./prepare-stock.sh from a NAND dump" >&2
    exit 1
  }
done
# U-Boot goes on the card verbatim and the kernel must stay byte-for-byte vendor.
python3 "$HERE/tools/source_manifest.py" verify "$PREPARED/source.json" "$PREPARED" --quiet

[ -f "$ROOTFS_TAR" ] || { echo "missing $ROOTFS_TAR (run ./build-rootfs.sh)" >&2; exit 1; }

mkdir -p "$WORK"

# tools/mkgpt.py is the single source of truth for the sector layout and
# for which partition root= must name.
eval "$(python3 "$HERE/tools/mkgpt.py" --shell)"

# The preloader installer stock picks up off the card. It goes on every mountable
# filesystem because stock's automounter picks which one it mounts by lock race
# (docs/02-sd-boot.md).
FWIMG="$WORK/miyoo355_fw.img"
python3 "$HERE/tools/preloader-installer/mkfwimg.py" "$FWIMG" >/dev/null

# The vendor command line uses all 100 available bytes and in-place FDT patching
# cannot grow it (tools/rkbootimg.py). `earlycon=` is dead weight on a unit with
# no UART attached, and dropping it makes room for what we do need:
#
#   init=/init   REQUIRED. For a disk root the kernel only tries /sbin/init,
#                /etc/init, /bin/init and /bin/sh — `/init` is the initramfs
#                convention. Without this the kernel execs /bin/sh, which waits
#                forever on a console that does not exist. H700 sets it too.
#   rw           init writes runtime state to the root filesystem.
# The vendor kernel is a raw 34.9 MiB arm64 Image and the bootloader reads every
# byte off the card each boot, so storing it compressed is the big pre-kernel
# lever: 4.96 s raw -> 3.14 s gzip -> 3.31 s lz4 (docs/01-boot-budget.md).
#
# Which formats are reachable is a property of the bootloader, and it is part of
# why the mainline path exists. The vendor U-Boot *sniffs* the Android payload
# for a magic it recognises — zImage, LZ4, gzip, LZMA — and there is no zstd
# case to add. A FIT declares its compression, so zstd becomes available:
# 12.99 MB gzip -> 10.84 MB zstd.
# MY355_COMPRESS_KERNEL = none | gzip | lz4, plus zstd on the mainline path.
case "$UBOOT" in
  vendor)   COMPRESS="${MY355_COMPRESS_KERNEL:-gzip}" ;;
  mainline) COMPRESS="${MY355_COMPRESS_KERNEL:-zstd}" ;;
esac

DROP="earlycon="
APPEND="rw init=$MY355_INIT"
LED_TRIGGER=""

if [ "$UBOOT" = vendor ]; then
  # The BaseOS wordmark, cropped from the shared artwork so branding matches the
  # H700 port. Size keeps the rebuilt resource image well under the largest one
  # proven to boot (tools/rkbootimg.py, RESOURCE_SAFE_BYTES).
  MY355_LOGO_SIZE="${MY355_LOGO_SIZE:-240x48}"
  MY355_LOGO_ASSET="${MY355_LOGO_ASSET:-$HERE/assets/bootlogo.bmp}"
  python3 "$HERE/tools/mkbootlogo.py" "$MY355_LOGO_ASSET" \
    "$WORK/baseos-logo.bmp" --size "$MY355_LOGO_SIZE" --preview

  echo "== repointing the vendor boot image at the card =="
  python3 "$HERE/tools/rkbootimg.py" setargs "$BOOT_SRC" "$WORK/boot-sd.img" \
    --root "$MY355_ROOT_DEV" --rootfstype ext4 --logo "$WORK/baseos-logo.bmp" \
    --drop "$DROP" --append "$APPEND" \
    ${LED_TRIGGER:+--led-trigger "$LED_TRIGGER"} \
    --compress-kernel "$COMPRESS"

  UBOOT_IMG="prepared/uboot.img"
  BOOT_PAYLOAD="boot-sd.img"
else
  # CONFIG_BOOTCOMMAND names one sector and three addresses, all fixed when
  # U-Boot was built. Check them against the layout about to be written rather
  # than shipping a card that reads the wrong place: this device has no console,
  # so the only symptom would be that it does not boot.
  echo "== mainline U-Boot =="
  for f in "$WORK/uboot-mainline.itb" "$WORK/uboot-mainline.json"; do
    [ -f "$f" ] || { echo "missing $f — run ./build-uboot.sh" >&2; exit 1; }
  done
  python3 "$HERE/tools/mkfit.py" verify-uboot \
    "$WORK/uboot-mainline.json" "$WORK/uboot-mainline.itb" \
    --boot-start "$MY355_BOOT_START"

  # No resource image on this path, so no logo: mainline U-Boot has no VOP2
  # driver for this SoC and draws nothing. The panel stays dark until the
  # kernel takes the display (docs/09-uboot.md).
  echo "== packing the vendor kernel into a FIT =="
  python3 "$HERE/tools/mkfit.py" boot "$BOOT_SRC" "$WORK/boot-fit.img" \
    --root "$MY355_ROOT_DEV" --rootfstype ext4 \
    --drop "$DROP" --append "$APPEND" \
    ${LED_TRIGGER:+--led-trigger "$LED_TRIGGER"} \
    --compress "$COMPRESS"

  UBOOT_IMG="uboot-mainline.itb"
  BOOT_PAYLOAD="boot-fit.img"
fi

# The payload is written at BOOT_START and the rootfs begins at ROOTFS_START.
# Nothing enforced that before, because the boot image only ever shrank — but an
# uncompressed kernel (MY355_COMPRESS_KERNEL=none) is 37.1 MB into 40 MiB of room,
# so the margin is thinner than it looks and silent corruption of the rootfs is a
# poor way to find out.
BOOT_ROOM=$(( (MY355_ROOTFS_START - MY355_BOOT_START) * 512 ))
BOOT_BYTES=$(wc -c < "$WORK/$BOOT_PAYLOAD")
[ "$BOOT_BYTES" -le "$BOOT_ROOM" ] || {
  echo "boot payload is $BOOT_BYTES bytes; the boot partition holds $BOOT_ROOM" >&2
  exit 1
}

echo "== composing $OUT =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work -v "$HERE/tools":/tools:ro \
  -e OUT_NAME="$(basename "$OUT")" \
  -e UBOOT_START="$MY355_UBOOT_START" -e BOOT_START="$MY355_BOOT_START" \
  -e UBOOT_IMG="$UBOOT_IMG" -e BOOT_PAYLOAD="$BOOT_PAYLOAD" \
  -e ROOTFS_START="$MY355_ROOTFS_START" -e SLOT_SECTORS="$MY355_SLOT_SECTORS" \
  -e DATA_START="$MY355_DATA_START" -e DATA_SECTORS="$MY355_DATA_SECTORS" \
  -e PRIMARY_START="$MY355_PRIMARY_START" -e PRIMARY_SECTORS="$MY355_PRIMARY_SECTORS" \
  alpine:3.20 sh -euc '
  apk add -q e2fsprogs e2fsprogs-extra dosfstools mtools python3 sgdisk

  OUT="/work/$OUT_NAME"
  rm -f "$OUT"; : > "$OUT"
  python3 /tools/mkgpt.py "$OUT"

  # The boot chain, whichever flavour was selected above: a FIT in `uboot`, and
  # in `boot` either the vendor Android image or our kernel FIT.
  dd if="/work/$UBOOT_IMG"    of="$OUT" bs=512 seek="$UBOOT_START" conv=notrunc status=none
  dd if="/work/$BOOT_PAYLOAD" of="$OUT" bs=512 seek="$BOOT_START"  conv=notrunc status=none

  # This kernel is 5.10.160. orphan_file needs 5.15+, so it must be off; the
  # other modern features are fine, unlike the H700 port and its 4.9 kernel.
  EXT4_OPTS="^orphan_file"

  R=/tmp/r; rm -rf "$R"; mkdir "$R"
  tar -xf /work/rootfs.tar -C "$R"
  cp /work/miyoo355_fw.img "$R/"
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L rootfs -d "$R" \
    -E offset=$((ROOTFS_START * 512)) "$OUT" $((SLOT_SECTORS / 8))

  # Slot B stays zeroed and unallocated: the first system update writes it.

  D=/tmp/d; rm -rf "$D"; mkdir "$D"; cp /work/miyoo355_fw.img "$D/"
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L data -d "$D" \
    -E offset=$((DATA_START * 512)) "$OUT" $((DATA_SECTORS / 8))

  # -s 1: the default 4 KiB clusters give 16092 here, under the 65525 a FAT32 needs.
  # Linux mounts that anyway; macOS refuses (docs/06-card-image-build.md).
  mkfs.vfat -F 32 -s 1 -n BASEOS -S 512 --offset "$PRIMARY_START" \
    "$OUT" $(((PRIMARY_SECTORS - 2048) / 2)) >/dev/null 2>&1
  mcopy -i "$OUT@@$((PRIMARY_START * 512))" /work/miyoo355_fw.img ::

  echo "-- verification --"
  sgdisk -v "$OUT" | tail -3
  dd if="$OUT" of=/tmp/rootfs.img bs=512 skip="$ROOTFS_START" count="$SLOT_SECTORS" status=none
  e2fsck -fn /tmp/rootfs.img >/dev/null && echo "  rootfs (slot A) ext4 OK"
  dd if="$OUT" of=/tmp/data.img bs=512 skip="$DATA_START" count="$DATA_SECTORS" status=none
  e2fsck -fn /tmp/data.img >/dev/null && echo "  data ext4 OK"
  n=0
  for off in "$ROOTFS_START" "$DATA_START"; do
    debugfs -R "stat /miyoo355_fw.img" "$OUT?offset=$((off * 512))" >/dev/null 2>&1 && n=$((n + 1))
  done
  mdir -i "$OUT@@$((PRIMARY_START * 512))" :: 2>/dev/null | grep -q -i miyoo355 && n=$((n + 1))
  [ "$n" -eq 3 ] && echo "  preloader installer on all 3 mountable filesystems"
'
if [ "$UBOOT" = vendor ]; then
  python3 "$HERE/tools/rkbootimg.py" info "$WORK/boot-sd.img" | grep -E "image id|bootargs"
else
  python3 "$HERE/tools/mkfit.py" info "$WORK/$BOOT_PAYLOAD"
fi
echo "bootloader: $UBOOT, kernel stored $COMPRESS"
echo "image: $OUT"
