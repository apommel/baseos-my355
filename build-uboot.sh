#!/bin/sh
# Build the mainline U-Boot that boots the vendor kernel on the my355 path.
#
# Produces, in work/my355:
#   uboot-mainline.itb    the FIT the SPL loads from the card's `uboot`
#                         partition: our U-Boot proper, plus the vendor's BL31,
#                         OP-TEE and control device tree byte-for-byte
#   uboot-mainline.json   what it was built with; build-image.sh checks it
#
# Then: ./build-image.sh (MY355_UBOOT=mainline is the default)
#
# Nothing here touches NAND. If the FIT is broken the SPL moves on to SPI NAND
# and stock comes up; reverting is a re-flash (docs/uboot.md).
#
# Environment:
#   MY355_UBOOT_DEBUG   0 (default): the release build.
#                       1: record the console and save it to the card, and
#                       signal stages on the charge LED (docs/diagnostics.md).
#                       7 ms slower; for bring-up and failed boots.
#   MY355_DIAG          1: also a bootstage mark after every initcall, to break
#                       U-Boot's own init down step by step (patches-diag/).
#                       Not for release builds.
#
# Usage: ./build-uboot.sh [--clean]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"

# The release ROCKNIX and Zlyme ship for this SoC, and the one that booted here.
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

DEBUG="${MY355_UBOOT_DEBUG:-0}"
case "$DEBUG" in 0|1) ;; *) echo "MY355_UBOOT_DEBUG must be 0 or 1" >&2; exit 1 ;; esac
DIAG="${MY355_DIAG:-0}"
case "$DIAG" in 0|1) ;; *) echo "MY355_DIAG must be 0 or 1" >&2; exit 1 ;; esac

CLEAN=0
case "${1:-}" in
  --clean) CLEAN=1 ;;
  -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

[ -f "$VENDOR_FIT" ] || { echo "missing $VENDOR_FIT — run ./fetch-prepared.sh" >&2; exit 1; }
mkdir -p "$CACHE" "$WORK"

if [ ! -f "$TARBALL" ] || [ "$(baseos_sha256 "$TARBALL")" != "$UBOOT_SHA256" ]; then
  echo "== fetching U-Boot $UBOOT_VERSION =="
  curl -fSL --retry 3 -o "$TARBALL.part" "$UBOOT_URL"
  got="$(baseos_sha256 "$TARBALL.part")"
  [ "$got" = "$UBOOT_SHA256" ] || {
    echo "u-boot tarball sha256 is $got, expected $UBOOT_SHA256" >&2
    rm -f "$TARBALL.part"; exit 1; }
  mv "$TARBALL.part" "$TARBALL"
fi

# The DRAM map and header layout come from the tool that writes the boot FIT.
eval "$(python3 "$HERE/tools/mkfit.py" addresses)"

# The boot script: PANEL and PREP may fail, LOAD may not, then bootm. bootm
# only returns on failure; then the board powers itself off rather than sit
# dark until the battery runs flat.
#
# The panel's supply (gpio0 PC7), which the kernel only switches on at ~2.0 s:
# powered from here, rkbootimg.py can drop the kernel's power-up waits.
PANEL="gpio set A23;"
# First, before the panel: charging off stays in U-Boot with the charge LED
# lit, until full, unplugged or the power key held; a flat battery powers off.
CHARGE="my355 charge;"
# PREP is `;`-separated: the boot survives each step refusing.
# The core clock before the card, so the read and the decompression run at it
# too. If it refuses, the boot carries on at 816 MHz.
PREP="my355 cpu 1104; my355 mark cpu_set;"
# The fuel gauge bookkeeping the vendor U-Boot does each boot; the kernel
# trusts it and would otherwise mistake charging while off for a crash. If it
# refuses, the kernel falls back to its own estimate.
PREP="$PREP my355 fg; my355 mark fg_sync;"
# Probing the card's block device binds one device per GPT entry slot, and each
# of the 128 lookups re-reads the 20-block entry array: 184 ms, as the cache
# only keeps reads of up to 8 blocks. 32 covers a full 128-entry array.
PREP="$PREP blkcache configure 32 32;"
# LOAD, `&&`-chained so a failure never reaches bootm with a stale buffer.
# `boot` is found by name because an A/B update moves it, and its header must
# carry both magic words before its length is trusted.
LOAD="mmc dev 1 && my355 mark mmc_ready"
LOAD="$LOAD && part start mmc 1 boot bs && part size mmc 1 boot bz"
LOAD="$LOAD && setexpr lg \${bs} + \${bz} && setexpr lg \${lg} - $MY355_LOG_SECTORS"
LOAD="$LOAD && mmc read $MY355_HDR_ADDR \${bs} 1"
LOAD="$LOAD && setexpr.l m *$MY355_HDR_ADDR && test \${m} = $MY355_HDR_MAGIC0"
LOAD="$LOAD && setexpr.l m *$(printf '%x' $((0x$MY355_HDR_ADDR + 4))) && test \${m} = $MY355_HDR_MAGIC1"
LOAD="$LOAD && setexpr.l n *$MY355_HDR_COUNT_ADDR && setexpr fs \${bs} + 1"
LOAD="$LOAD && mmc read $MY355_FIT_ADDR \${fs} \${n} && my355 mark fit_read"
# bootm in its steps, to decompress at 1800 MHz: the kernel must not inherit
# more than 1104 (my355 cpu), so a failed return to it stops the boot. A failed
# raise only leaves decompression at 1104.
BOOT="env exists ok && my355 cpu 1800; env exists ok && bootm start $MY355_FIT_ADDR"
BOOT="$BOOT && bootm loados && my355 mark decompressed && my355 cpu 1104"
BOOT="$BOOT && bootm prep && bootm go"
if [ "$DEBUG" = 1 ]; then
  # The last 64 KiB of the active `boot` slot, located from the partition itself;
  # `lg` exists only once `part` found it, so a failure before then writes nothing.
  SAVELOG="env exists lg && mw.b $MY355_LOG_ADDR 0 $MY355_LOG_BYTES"
  SAVELOG="$SAVELOG && my355 log $MY355_LOG_ADDR $MY355_LOG_BYTES"
  SAVELOG="$SAVELOG && mmc write $MY355_LOG_ADDR \${lg} $MY355_LOG_SECTORS"
  # What the card was actually driven at, and the CRU's drive/sample phases,
  # which U-Boot never programs (SDMMC0_CON0/1).
  CARDINFO="mmc info; md.l fdd20580 2"
  # gpio0 PC2, the charge LED: lit once init is done, dark once the kernel is
  # read. Saving the log is kept off the boot path's && chain so that a failed
  # write can never stop the boot; it runs again after a failed bootm.
  BOOTCMD="$CHARGE $PANEL gpio set A18; $PREP $LOAD && gpio clear A18 && setenv ok 1; $CARDINFO; $SAVELOG;"
  BOOTCMD="$BOOTCMD $BOOT; $SAVELOG; poweroff"
else
  BOOTCMD="$CHARGE $PANEL $PREP $LOAD && setenv ok 1; $BOOT; poweroff"
fi

FRAGMENTS="/frag/my355.config"
[ "$DEBUG" = 1 ] && FRAGMENTS="$FRAGMENTS /frag/my355-debug.config"
[ "$DIAG" = 1 ] && FRAGMENTS="$FRAGMENTS /frag/my355-diag.config"
# Applied in this order; the diagnostics go on top of the real patch set.
PATCHES="patches/*.patch"
[ "$DIAG" = 1 ] && PATCHES="$PATCHES patches-diag/*.patch"

echo "== building U-Boot $UBOOT_VERSION ($UBOOT_DEFCONFIG, debug=$DEBUG, diag=$DIAG) =="
echo "   bootcmd: $BOOTCMD"

[ "$CLEAN" -eq 1 ] && rm -rf "$BUILD"
# The extracted tree is cached and patched once, so a changed patch set must
# force a fresh extraction or it would silently be missing from the build.
# shellcheck disable=SC2086
(cd "$HERE/tools/uboot" && cat $PATCHES) > "$CACHE/patches.cat"
PATCH_SUM="$(baseos_sha256 "$CACHE/patches.cat")"
[ "$(cat "$CACHE/patches.sha256" 2>/dev/null || true)" = "$PATCH_SUM" ] || rm -rf "$BUILD"
mkdir -p "$BUILD"

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$CACHE":/cache -v "$HERE/tools/uboot":/frag:ro \
  -e UBOOT_VERSION="$UBOOT_VERSION" -e UBOOT_DEFCONFIG="$UBOOT_DEFCONFIG" \
  -e BOOTCMD="$BOOTCMD" -e FRAGMENTS="$FRAGMENTS" -e PATCHES="$PATCHES" \
  debian:bookworm-slim sh -euc '
  export DEBIAN_FRONTEND=noninteractive
  # An arm64 host builds natively; anything else cross-compiles.
  if [ "$(uname -m)" = aarch64 ]; then CC_PKG=gcc; CROSS=; else
    CC_PKG=gcc-aarch64-linux-gnu; CROSS=aarch64-linux-gnu-; fi
  apt-get -qq update
  apt-get -qq install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev patch python3 python3-dev \
    python3-setuptools python3-pyelftools device-tree-compiler \
    libgnutls28-dev uuid-dev swig "$CC_PKG" >/dev/null

  SRC="/cache/build/u-boot-${UBOOT_VERSION#v}"
  if [ ! -d "$SRC" ]; then
    tar -xf "/cache/u-boot-$UBOOT_VERSION.tar.gz" -C /cache/build
    # shellcheck disable=SC2086
    for p in $(cd /frag && echo $PATCHES); do
      p="/frag/$p"
      echo "  patch: $(basename "$p")"
      patch -p1 -d "$SRC" --batch --forward --quiet < "$p"
    done
  fi
  cd "$SRC"
  # Copied every build, not patched in once, so an edit is always picked up.
  cp /frag/dts/*.dts arch/arm/dts/

  export CROSS_COMPILE="$CROSS"
  # Same inputs, same FIT: "did the bootloader change?" is a checksum question.
  export SOURCE_DATE_EPOCH=0

  printf "CONFIG_BOOTCOMMAND=\"%s\"\n" "$BOOTCMD" > /tmp/bootcmd.config
  make "$UBOOT_DEFCONFIG" >/dev/null
  # shellcheck disable=SC2086
  ./scripts/kconfig/merge_config.sh -m -O . .config $FRAGMENTS /tmp/bootcmd.config >/dev/null
  make olddefconfig >/dev/null

  # Kconfig drops a fragment line silently (a `select`, a `depends on`, a
  # `choice`), and a stripped binary on a unit with no console will not say so.
  fail=0
  for frag in $FRAGMENTS /tmp/bootcmd.config; do
    while IFS= read -r line; do
      case "$line" in
        "#"*"is not set")
          sym=$(printf "%s" "$line" | sed -e "s/^# *//" -e "s/ is not set$//")
          if grep -q "^$sym=" .config; then
            echo "  NOT DISABLED: $sym -> $(grep "^$sym=" .config)" >&2; fail=1
          fi ;;
        CONFIG_*)
          grep -qxF "$line" .config || {
            sym=${line%%=*}
            echo "  NOT APPLIED:  $line (got: $(grep "^$sym=" .config || echo absent))" >&2
            fail=1; } ;;
      esac
    done < "$frag"
  done
  [ "$fail" -eq 0 ] || { echo "config assertions failed" >&2; exit 1; }
  echo "  config: every fragment line survived olddefconfig"

  make -j"$(nproc)" u-boot.bin >/dev/null

  # CONFIG_OF_SEPARATE appends the control device tree; without it U-Boot has
  # no tree at all and dies before the card.
  nodtb=$(stat -c %s u-boot-nodtb.bin); full=$(stat -c %s u-boot.bin)
  [ "$full" -gt "$nodtb" ] || { echo "u-boot.bin has no appended device tree" >&2; exit 1; }
  cp u-boot.bin /cache/u-boot.bin
  sed -n "s/^CONFIG_TEXT_BASE=//p" .config > /cache/text-base
  strings -a u-boot.bin | grep -m1 "^U-Boot 20" > /cache/version || true
  echo "  u-boot.bin: $full bytes (device tree $((full - nodtb)) bytes)"
'
# Only after a good build, so a failed one leaves the stamp stale.
printf '%s\n' "$PATCH_SUM" > "$CACHE/patches.sha256"

TEXT_BASE="$(cat "$CACHE/text-base")"
echo "== composing $OUT =="
python3 "$HERE/tools/mkfit.py" uboot "$VENDOR_FIT" "$CACHE/u-boot.bin" "$OUT" \
  --uboot-load "$TEXT_BASE"

eval "$(python3 "$HERE/tools/mkgpt.py" --shell)"
ROOM=$((MY355_UBOOT_SLOT_SECTORS * 512))
BYTES=$(wc -c < "$OUT" | tr -d ' ')
[ "$BYTES" -le "$ROOM" ] || { echo "the FIT is $BYTES bytes; the uboot slot holds $ROOM" >&2; exit 1; }

BANNER="$(cat "$CACHE/version" 2>/dev/null || echo "U-Boot $UBOOT_VERSION")" \
SHA="$(baseos_sha256 "$OUT")" BOOTCMD="$BOOTCMD" DEBUG="$DEBUG" DIAG="$DIAG" TEXT_BASE="$TEXT_BASE" \
UBOOT_VERSION="$UBOOT_VERSION" UBOOT_DEFCONFIG="$UBOOT_DEFCONFIG" \
python3 - "$META" "$HERE/tools" <<'EOF'
import json, os, sys
sys.path.insert(0, sys.argv[2])
import mkfit
e = os.environ
json.dump({"uboot_version": e["UBOOT_VERSION"], "banner": e["BANNER"],
           "defconfig": e["UBOOT_DEFCONFIG"], "debug": e["DEBUG"] == "1",
           "diag": e["DIAG"] == "1",
           "text_base": e["TEXT_BASE"], "bootcmd": e["BOOTCMD"],
           "addresses": mkfit.addresses(), "sha256": e["SHA"]},
          open(sys.argv[1], "w"), indent=2)
EOF

echo
echo "  $(cat "$CACHE/version" 2>/dev/null)"
echo "  $OUT  ($BYTES bytes)"
echo "  next: ./build-image.sh"
