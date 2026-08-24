#!/bin/sh
# Build the mainline U-Boot BaseOS boots the vendor kernel from.
#
# The Flip's largest single boot cost is the vendor U-Boot's own 1.21 s of
# initialisation before it fetches a byte, and the 10.9 MB/s it then reads the
# card at against ~25 MB/s of available bandwidth (docs/01-boot-budget.md).
# Neither is reachable from a device tree, so this replaces the binary.
#
# What it produces, in work/my355:
#   uboot-mainline.itb    the FIT the SPL loads from the card's `uboot`
#                         partition: our U-Boot proper, plus the vendor's BL31,
#                         OP-TEE and control device tree, byte-for-byte
#   uboot-mainline.json   what that build assumed — the sector it reads the
#                         kernel from, its load addresses, its bootcmd
#
# Nothing here touches NAND. If the FIT is missing or broken the SPL walks its
# boot order on to the SPI NAND and stock comes up, so the failure mode is
# "this card does not boot" and reverting is a re-flash (docs/02-sd-boot.md).
#
# Then: MY355_UBOOT=mainline ./build-image.sh
#
# Usage: ./build-uboot.sh [--clean]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

# Mainline, at the release ROCKNIX ships for every RK3566 handheld — so the
# board support this leans on is the code path that already runs on this SoC.
UBOOT_VERSION="v2026.01"
UBOOT_SHA256="03bb43c58d2343ee48dd191e0f181f0108425b179d84519add3a977071c3f654"
UBOOT_URL="https://github.com/u-boot/u-boot/archive/refs/tags/$UBOOT_VERSION.tar.gz"
UBOOT_DEFCONFIG="quartz64-a-rk3566_defconfig"

WORK="$HERE/work/my355"
CACHE="$HERE/work/uboot"
BUILD="$CACHE/build"
TARBALL="$CACHE/u-boot-$UBOOT_VERSION.tar.gz"
VENDOR_FIT="$WORK/prepared/uboot.img"
OUT="$WORK/uboot-mainline.itb"
META="$WORK/uboot-mainline.json"

CLEAN=0
case "${1:-}" in
  --clean) CLEAN=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

[ -f "$VENDOR_FIT" ] || {
  echo "missing $VENDOR_FIT — run ./fetch-prepared.sh" >&2
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

mkdir -p "$CACHE" "$WORK"

if [ ! -f "$TARBALL" ] || [ "$(sha256_of "$TARBALL")" != "$UBOOT_SHA256" ]; then
  echo "== fetching U-Boot $UBOOT_VERSION =="
  curl -fSL --retry 3 -o "$TARBALL.part" "$UBOOT_URL"
  got="$(sha256_of "$TARBALL.part")"
  [ "$got" = "$UBOOT_SHA256" ] || {
    echo "u-boot tarball sha256 is $got, expected $UBOOT_SHA256" >&2
    rm -f "$TARBALL.part"
    exit 1
  }
  mv "$TARBALL.part" "$TARBALL"
fi

# The sector the payload lives at and the addresses U-Boot parks it at are both
# baked into CONFIG_BOOTCOMMAND, so they come from the tools that own them
# rather than being written twice.
eval "$(python3 "$HERE/tools/mkgpt.py" --shell)"
eval "$(python3 "$HERE/tools/mkfit.py" addresses)"

HDR_SECTOR="$(printf '%x' "$MY355_BOOT_START")"
FIT_SECTOR="$(printf '%x' "$((MY355_BOOT_START + 1))")"
# setexpr parses the address after `*` with hextoul(), so it must be hex.
COUNT_ADDR="$(printf '%x' "$((0x$MY355_HDR_ADDR + 0x$MY355_HDR_COUNT_OFF))")"

# Read the header sector, take the FIT's length out of it, read exactly that
# many sectors, boot. No filesystem, no scan, no probe of anything else.
BOOTCMD="mmc dev 1;"
BOOTCMD="$BOOTCMD mmc read $MY355_HDR_ADDR $HDR_SECTOR 1;"
BOOTCMD="$BOOTCMD setexpr.l fitsz *$COUNT_ADDR;"
BOOTCMD="$BOOTCMD mmc read $MY355_FIT_ADDR $FIT_SECTOR \${fitsz};"
BOOTCMD="$BOOTCMD bootm $MY355_FIT_ADDR"

echo "== building U-Boot $UBOOT_VERSION ($UBOOT_DEFCONFIG + tools/uboot/my355.config) =="
echo "   bootcmd: $BOOTCMD"

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD"
mkdir -p "$BUILD"

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$CACHE":/cache -v "$HERE/tools/uboot":/frag:ro \
  -e UBOOT_VERSION="$UBOOT_VERSION" -e UBOOT_DEFCONFIG="$UBOOT_DEFCONFIG" \
  -e BOOTCMD="$BOOTCMD" \
  debian:bookworm-slim sh -euc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update
  apt-get -qq install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev python3 python3-dev \
    python3-setuptools python3-pyelftools device-tree-compiler \
    gcc-aarch64-linux-gnu libgnutls28-dev uuid-dev swig >/dev/null

  SRC="/cache/build/u-boot-${UBOOT_VERSION#v}"
  [ -d "$SRC" ] || tar -xf "/cache/u-boot-$UBOOT_VERSION.tar.gz" -C /cache/build
  cd "$SRC"

  # ARCH is deliberately not set: config.mk derives it from CONFIG_SYS_ARCH.
  export CROSS_COMPILE=aarch64-linux-gnu-
  # A fixed timestamp so the same inputs give the same FIT, which is also what
  # makes "did the bootloader actually change?" answerable with a checksum.
  export SOURCE_DATE_EPOCH=0

  printf "CONFIG_BOOTCOMMAND=\"%s\"\n" "$BOOTCMD" > /tmp/bootcmd.config

  make "$UBOOT_DEFCONFIG" >/dev/null
  ./scripts/kconfig/merge_config.sh -m -O . .config \
    /frag/my355.config /tmp/bootcmd.config >/dev/null
  make olddefconfig >/dev/null

  # merge_config warns about overridden symbols; Kconfig dependencies can drop
  # them again. Neither is visible in a 900 KB binary, and this device has no
  # console to notice a U-Boot that still waits two seconds, so assert instead.
  fail=0
  while IFS= read -r line; do
    case "$line" in
      "#"*"is not set")
        sym=$(printf "%s" "$line" | sed -e "s/^# *//" -e "s/ is not set$//")
        if grep -q "^$sym=" .config; then
          echo "  NOT DISABLED: $sym -> $(grep "^$sym=" .config)" >&2
          fail=1
        fi
        ;;
      CONFIG_*)
        grep -qxF "$line" .config || {
          sym=${line%%=*}
          echo "  NOT APPLIED:  $line (got: $(grep "^$sym=" .config || echo absent))" >&2
          fail=1
        }
        ;;
    esac
  done < /frag/my355.config
  grep -qxF "$(cat /tmp/bootcmd.config)" .config || {
    echo "  NOT APPLIED:  CONFIG_BOOTCOMMAND" >&2
    fail=1
  }
  [ "$fail" -eq 0 ] || { echo "config assertions failed" >&2; exit 1; }
  echo "  config: every line of my355.config survived olddefconfig"

  make -j"$(nproc)" u-boot.bin >/dev/null

  # CONFIG_OF_SEPARATE appends the control device tree to u-boot.bin; without
  # it U-Boot comes up with no device tree at all and dies before the card.
  nodtb=$(stat -c %s u-boot-nodtb.bin)
  full=$(stat -c %s u-boot.bin)
  [ "$full" -gt "$nodtb" ] || {
    echo "u-boot.bin ($full) is not larger than u-boot-nodtb.bin ($nodtb) — no appended dtb" >&2
    exit 1
  }
  cp u-boot.bin /cache/u-boot.bin
  grep "^CONFIG_TEXT_BASE=" .config > /cache/text-base
  strings -a u-boot.bin | grep -m1 "^U-Boot 20" > /cache/version || true
  echo "  u-boot.bin: $full bytes (dtb $((full - nodtb)) bytes appended)"
'

TEXT_BASE="$(cut -d= -f2 < "$CACHE/text-base")"
UBOOT_BANNER="$(cat "$CACHE/version" 2>/dev/null || echo "$UBOOT_VERSION")"

echo "== composing $OUT =="
python3 "$HERE/tools/mkfit.py" uboot "$VENDOR_FIT" "$CACHE/u-boot.bin" "$OUT" \
  --uboot-load "$TEXT_BASE"

UBOOT_ROOM=$(( (MY355_BOOT_START - MY355_UBOOT_START) * 512 ))
ITB_BYTES=$(wc -c < "$OUT" | tr -d ' ')
[ "$ITB_BYTES" -le "$UBOOT_ROOM" ] || {
  echo "the FIT is $ITB_BYTES bytes; the uboot partition holds $UBOOT_ROOM" >&2
  exit 1
}

# build-image.sh refuses a card whose layout this build did not assume.
cat > "$META" <<JSON
{
  "uboot_version": "$UBOOT_VERSION",
  "banner": "$UBOOT_BANNER",
  "defconfig": "$UBOOT_DEFCONFIG",
  "text_base": "$TEXT_BASE",
  "boot_start": $MY355_BOOT_START,
  "kernel_addr": "0x$MY355_KERNEL_ADDR",
  "fit_addr": "0x$MY355_FIT_ADDR",
  "hdr_addr": "0x$MY355_HDR_ADDR",
  "bootcmd": "$BOOTCMD",
  "sha256": "$(sha256_of "$OUT")"
}
JSON

echo
echo "  $UBOOT_BANNER"
echo "  $OUT  ($ITB_BYTES bytes of $UBOOT_ROOM)"
echo "  next: MY355_UBOOT=mainline ./build-image.sh"
