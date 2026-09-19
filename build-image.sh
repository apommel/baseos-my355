#!/bin/sh
# Compose the bootable BaseOS SD card image for my355 (Miyoo Flip).
#
# The Flip's boot chain lives in internal SPI NAND, so the card supplies only
# what that chain reaches for — a U-Boot FIT in a GPT partition named `uboot`,
# and whatever that U-Boot boots from one named `boot` — plus the BaseOS rootfs.
#
# This requires a preloader with a working /pinctrl in mtd5; see docs/boot-chain.md.
#
# Inputs come from ./fetch-prepared.sh or ./prepare-stock.sh, in
# work/my355/prepared:
#   uboot.img   stock Rockchip U-Boot FIT, used verbatim
#   boot.img    stock Android boot image; the kernel stays byte-for-byte
#               identical, only the DTB's bootargs and logo are rewritten
#
# Environment:
#   MY355_UBOOT      mainline (default): ./build-uboot.sh's FIT, booting a FIT
#                    of the vendor kernel (docs/uboot.md). vendor: the stock
#                    U-Boot FIT verbatim, booting a rewritten Android boot image.
#   MY355_SD_UHS     boot slot UHS ceiling: off | sdr50 | sdr104 (default
#                    sdr104; the vendor caps at sdr25 = 50 MHz = 22 MB/s)
#   MY355_COMPRESS_KERNEL   vendor: gzip (default) | none
#                    mainline: zstd (default) | gzip
#   MY355_INITCALL_BLACKLIST  built-in initcalls to skip; empty restores the
#                    vendor set
#   MY355_LOGO_SIZE, MY355_LOGO_ASSET   boot logo
#
# Usage: ./build-image.sh
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"

WORK="$HERE/work/my355"
PREPARED="$WORK/prepared"
OUT="$WORK/baseos-my355.img"
ROOTFS_TAR="$WORK/rootfs.tar"
UBOOT_SRC="$PREPARED/uboot.img"
BOOT_SRC="$PREPARED/boot.img"

# The kernel must stay byte-for-byte vendor, and so must U-Boot on the vendor path.
baseos_require_prepared "$PREPARED"

UBOOT="${MY355_UBOOT:-mainline}"
case "$UBOOT" in
  vendor)
    UBOOT_IMG="$UBOOT_SRC"
    BOOT_IMG="$WORK/boot-sd.img" ;;
  mainline)
    UBOOT_IMG="$WORK/uboot-mainline.itb"
    BOOT_IMG="$WORK/boot-fit.img"
    [ -f "$UBOOT_IMG" ] && [ -f "$WORK/uboot-mainline.json" ] || {
      echo "missing $UBOOT_IMG (run ./build-uboot.sh)" >&2; exit 1; }
    # Its boot script bakes in mkfit.py's DRAM map and header layout.
    python3 "$HERE/tools/mkfit.py" verify-uboot "$WORK/uboot-mainline.json" "$UBOOT_IMG" ;;
  *) echo "MY355_UBOOT must be vendor or mainline (got '$UBOOT')" >&2; exit 1 ;;
esac

[ -f "$ROOTFS_TAR" ] || { echo "missing $ROOTFS_TAR (run ./build-rootfs.sh)" >&2; exit 1; }

mkdir -p "$WORK"

# tools/mkgpt.py is the single source of truth for the sector layout and
# for which partition root= must name.
eval "$(python3 "$HERE/tools/mkgpt.py" --shell)"

# The preloader installer stock picks up off the card. It goes on every mountable
# filesystem because stock's automounter picks which one it mounts by lock race
# (docs/boot-chain.md).
FWIMG="$WORK/miyoo355_fw.img"
python3 "$HERE/tools/preloader-installer/mkfwimg.py" "$FWIMG" >/dev/null

# The vendor kernel is a raw 34.9 MiB arm64 Image and U-Boot reads every byte off
# the card each boot, so storing it compressed is the big pre-kernel lever:
# 4.96 s raw -> 2.86 s gzip.
if [ "$UBOOT" = mainline ]; then
  COMPRESS="${MY355_COMPRESS_KERNEL:-zstd}"   # zstd | gzip
else
  COMPRESS="${MY355_COMPRESS_KERNEL:-gzip}"   # none | gzip
fi

# The vendor DTB declares sd-uhs-sdr12/sdr25 on the boot slot and stops there,
# which pins the bus at 50 MHz: both cards measure 22.3 MB/s, exactly the SDR25
# ceiling, so the controller is the limit and not the media. The RK3566 sdmmc
# does SDR104, max-frequency is already 150 MHz, and vccio_sd already sits at
# 1.8 V because the card negotiates SDR25 today — so this is a clock change, not
# a voltage change. Slot 1 cannot follow: its pins are on a fixed 3.3 V domain.
# Modes negotiate down, so a card that cannot do SDR104 lands on SDR50 or SDR25
# by itself. Set MY355_SD_UHS=sdr50 to be conservative, or =off for the vendor
# behaviour. See docs/boot-time.md.
SD_UHS="${MY355_SD_UHS:-sdr104}"              # off | sdr50 | sdr104
case "$SD_UHS" in
  off|sdr50|sdr104) ;;
  *) echo "MY355_SD_UHS must be off, sdr50 or sdr104 (got '$SD_UHS')" >&2; exit 1 ;;
esac

# Built-in initcalls skipped by name, so the kernel stays the vendor's
# byte-for-byte: tracefs is never mounted (0.38 s), OHCI only serves the
# high-speed WiFi/BT chip (0.12 s), alpu is the anti-clone chip (0.11 s).
# MY355_INITCALL_BLACKLIST="" restores the vendor set. See docs/boot-time.md.
INITCALL_BLACKLIST="${MY355_INITCALL_BLACKLIST-tracer_init_tracefs,ohci_platform_init,alpu_init}"

# The vendor command line fills its 100-byte slot; rkbootimg.py grows the FDT
# when ours does not fit. `earlycon=` is dead weight on a unit with no UART
# attached, so it goes. What we add:
#
#   init=/init   REQUIRED. For a disk root the kernel only tries /sbin/init,
#                /etc/init, /bin/init and /bin/sh — `/init` is the initramfs
#                convention. Without this the kernel execs /bin/sh, which waits
#                forever on a console that does not exist.
#   rw           init writes runtime state to the root filesystem.
#   quiet        nothing to the FIQ debugger UART, which no one reads; dmesg
#                still holds every line.
#   cpufreq.default_governor=performance
#                full speed from cpufreq's probe (~0.58 s into the kernel) until
#                the frontend picks its own; frontend-session drops to ondemand
#                when there is none.
DROP="earlycon="
APPEND="rw init=/init quiet cpufreq.default_governor=performance${INITCALL_BLACKLIST:+ initcall_blacklist=$INITCALL_BLACKLIST}"

# The BaseOS wordmark. Size keeps the rebuilt resource image well under the
# largest one proven to boot (tools/rkbootimg.py, RESOURCE_SAFE_BYTES).
MY355_LOGO_SIZE="${MY355_LOGO_SIZE:-240x48}"
MY355_LOGO_ASSET="${MY355_LOGO_ASSET:-$HERE/assets/bootlogo.bmp}"
python3 "$HERE/tools/mkbootlogo.py" "$MY355_LOGO_ASSET" \
  "$WORK/baseos-logo.bmp" --size "$MY355_LOGO_SIZE" --preview

# In Alpine so the gzip encoder (libdeflate) comes pinned with the release rather
# than from whatever the host has installed.
if [ "$UBOOT" = vendor ]; then
  echo "== repointing the vendor boot image at the card =="
  set -- rkbootimg.py setargs --logo /work/baseos-logo.bmp --compress-kernel "$COMPRESS"
else
  # A FIT names its compression, so zstd is reachable here and not on the
  # vendor path. No logo: mainline U-Boot has no display driver for this SoC.
  case "$COMPRESS" in zstd|gzip) ;; *)
    echo "the mainline path stores the kernel as zstd or gzip" >&2; exit 1 ;; esac
  echo "== packing the vendor kernel and device tree as a FIT =="
  set -- mkfit.py boot --compress "$COMPRESS" --slot-sectors "$MY355_BOOT_SLOT_SECTORS"
fi
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work -v "$HERE/tools":/tools:ro \
  alpine:3.20 sh -euc '
  apk add -q python3 libdeflate-utils zstd
  tool=$1 cmd=$2; shift 2
  python3 "/tools/$tool" "$cmd" "/work/prepared/boot.img" "$@"' sh \
  "$@" "/work/$(basename "$BOOT_IMG")" \
  --root "$MY355_ROOT_DEV" --rootfstype ext4 \
  --drop "$DROP" --append "$APPEND" \
  --sd-uhs "$SD_UHS"

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
  apk add -q e2fsprogs e2fsprogs-extra dosfstools mtools python3 sgdisk

  OUT="/work/$OUT_NAME"
  rm -f "$OUT"; : > "$OUT"
  python3 /tools/mkgpt.py "$OUT"

  dd if="/work/$UBOOT_IMG" of="$OUT" bs=512 seek="$UBOOT_START" conv=notrunc status=none
  dd if="/work/$BOOT_IMG"  of="$OUT" bs=512 seek="$BOOT_START"  conv=notrunc status=none

  # This kernel is 5.10.160. orphan_file needs 5.15+, so it must be off; the
  # other modern features are fine.
  EXT4_OPTS="^orphan_file"

  R=/tmp/r; rm -rf "$R"; mkdir "$R"
  tar -xf /work/rootfs.tar -C "$R"
  cp /work/miyoo355_fw.img "$R/"
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L rootfs -d "$R" \
    -E offset=$((ROOTFS_START * 512)) "$OUT" $((SLOT_SECTORS / 8))

  # The reserved half of each region stays zeroed: the first update writes it.

  D=/tmp/d; rm -rf "$D"; mkdir "$D"; cp /work/miyoo355_fw.img "$D/"
  mke2fs -q -F -t ext4 -O "$EXT4_OPTS" -b 4096 -L data -d "$D" \
    -E offset=$((DATA_START * 512)) "$OUT" $((DATA_SECTORS / 8))

  # Pre-expansion geometry only: first boot reformats this partition at full
  # size with a normal cluster size. -s 1 because the default 4 KiB clusters
  # give 16092 here, under the 65525 a FAT32 needs -- Linux mounts that anyway,
  # macOS refuses (docs/card.md).
  mkfs.vfat -F 32 -s 1 -n BASEOS -S 512 --offset "$PRIMARY_START" \
    "$OUT" $(((PRIMARY_SECTORS - 2048) / 2)) >/dev/null 2>&1
  mcopy -i "$OUT@@$((PRIMARY_START * 512))" /work/miyoo355_fw.img ::

  echo "-- verification --"
  sgdisk -v "$OUT" | tail -3
  dd if="$OUT" of=/tmp/rootfs.img bs=512 skip="$ROOTFS_START" count="$SLOT_SECTORS" status=none
  e2fsck -fn /tmp/rootfs.img >/dev/null && echo "  rootfs ext4 OK"
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
  python3 "$HERE/tools/rkbootimg.py" info "$BOOT_IMG" | grep -E "image id|bootargs"
else
  python3 "$HERE/tools/mkfit.py" info "$BOOT_IMG"
fi
echo "image: $OUT (U-Boot: $UBOOT)"
