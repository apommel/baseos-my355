#!/bin/sh
# Builds BaseOS for the Miyoo Flip with Buildroot, in Docker (docs/rootfs.md).
#
# Usage: ./build.sh [--diag] [--clean] [make target ...]
#   --diag   boot-timing and console aids, not for release (docs/diagnostics.md)
#   --clean  start from an empty output directory
#   e.g. ./build.sh linux-rebuild all, or ./build.sh sdk
#
# Writes work/images: baseos-my355-<version>.img.zip for a new card, .bosupd
# to update one, SHA256SUMS, and Buildroot's own images. The output tree and
# ccache live in a Docker volume, downloads in work/dl. The first build takes
# a few hours; later ones rebuild what changed.
#
# STOCK_FIRMWARE=<dir> takes uboot.img and stock-harvest.tar from a dump of
# your own instead of the published bundle (CONTRIBUTING.md).
# BASEOS_BUILD_DIR=<absolute dir> keeps the output tree and ccache there
# instead of the Docker volume, so CI can cache them.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
BR_VERSION="2026.08.1"
BR_SHA256="34fb7bea8a213ffde39cc02e61703391560f26e0850f03138c722d0b09880f2b"
# Rockchip's libmali-next: the repository holds every GPU's blobs, so only
# the G52's is checked out.
LIBMALI_COMMIT="bf621d15f009509557d6b28f81427651695cac20"
LIBMALI_BLOB="lib/aarch64-linux-gnu/libmali-bifrost-g52-g29p1.so"
LIBMALI_SHA256="605e3a5caf1be62bb48d97b1168434257355d56db5e3be9b515cfa742c173118"

DL="$HERE/work/dl"
IMAGES="$HERE/work/images"
OUTPUT=output
DIAG=0 CLEAN=0
while :; do
  case "${1:-}" in
    --diag) DIAG=1 OUTPUT=output-diag; shift ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
# src/ is a local package, which Buildroot does not watch for changes.
TARGETS="${*:-baseos-tools-rebuild all}"
STOCK_MOUNT=
if [ -n "${STOCK_FIRMWARE:-}" ]; then
  STOCK_MOUNT="-v $(cd "$STOCK_FIRMWARE" && pwd):/stock:ro"
  TARGETS="STOCK_FIRMWARE_OVERRIDE_SRCDIR=/stock $TARGETS"
fi

# macOS has shasum, Linux sha256sum.
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

BR_TAR="$DL/buildroot-$BR_VERSION.tar.xz"
mkdir -p "$DL" "$IMAGES"
if [ "$(sha256 "$BR_TAR" 2>/dev/null)" != "$BR_SHA256" ]; then
  curl -fSL --retry 3 -o "$BR_TAR" "https://buildroot.org/downloads/buildroot-$BR_VERSION.tar.xz"
  [ "$(sha256 "$BR_TAR")" = "$BR_SHA256" ] || { echo "buildroot: bad sha256" >&2; exit 1; }
fi

LIBMALI="$DL/libmali-$LIBMALI_COMMIT"
if [ "$(sha256 "$LIBMALI/$LIBMALI_BLOB" 2>/dev/null)" != "$LIBMALI_SHA256" ]; then
  rm -rf "$LIBMALI"
  git init -q "$LIBMALI"
  git -C "$LIBMALI" sparse-checkout set --no-cone '/*' '!/lib/' "/$LIBMALI_BLOB" '!/data/vulkan/lib/arm/'
  git -C "$LIBMALI" fetch -q --depth 1 --filter=blob:none https://github.com/JeffyCN/mirrors.git "$LIBMALI_COMMIT"
  git -C "$LIBMALI" checkout -q FETCH_HEAD
  [ "$(sha256 "$LIBMALI/$LIBMALI_BLOB")" = "$LIBMALI_SHA256" ] || { echo "libmali: bad sha256" >&2; exit 1; }
fi

BASEOS_VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
BASEOS_BUILD="$(git -C "$HERE" describe --always --dirty 2>/dev/null || echo unknown)"
# A card skips a same-version payload with its own build id.
case "$BASEOS_BUILD" in *-dirty) BASEOS_BUILD="$BASEOS_BUILD-$(date -u +%Y%m%d%H%M%S)" ;; esac

echo "== BaseOS $BASEOS_VERSION ($BASEOS_BUILD): make $TARGETS, log in work/build.log =="
docker run --rm --platform linux/arm64 \
  -v "${BASEOS_BUILD_DIR:-baseos-buildroot}":/build -v "$DL":/dl -v "$IMAGES":/images \
  -v "$HERE":/baseos:ro -v "$LIBMALI":/src/libmali:ro $STOCK_MOUNT \
  -e BR_VERSION="$BR_VERSION" -e TARGETS="$TARGETS" -e O="/build/$OUTPUT" \
  -e DIAG="$DIAG" -e CLEAN="$CLEAN" \
  -e BASEOS_VERSION="$BASEOS_VERSION" -e BASEOS_BUILD="$BASEOS_BUILD" \
  debian:trixie-slim sh -euc '
  export DEBIAN_FRONTEND=noninteractive FORCE_UNSAFE_CONFIGURE=1
  apt-get -qq update >/dev/null
  apt-get -qq install -y --no-install-recommends build-essential file wget cpio unzip \
    rsync bc git ca-certificates python3 perl patch xz-utils bzip2 gzip libncurses-dev \
    cmake >/dev/null
  B=/build/buildroot-$BR_VERSION
  [ -d "$B" ] || tar -xJf /dl/buildroot-$BR_VERSION.tar.xz -C /build
  [ "$CLEAN" = 0 ] || rm -rf "$O"
  cat /baseos/configs/baseos_my355_defconfig > /tmp/defconfig
  [ "$DIAG" = 0 ] || cat /baseos/board/my355/diag/defconfig.fragment >> /tmp/defconfig
  make -C "$B" O="$O" BR2_EXTERNAL=/baseos BR2_DEFCONFIG=/tmp/defconfig defconfig >/dev/null
  # shellcheck disable=SC2086
  make -C "$B" O="$O" BR2_SDK_PREFIX=baseos-my355-sdk $TARGETS >/images/build.log 2>&1 ||
    { tail -40 /images/build.log >&2; exit 1; }
  rm -rf /images/*.img /images/*.bosupd /images/*.zip
  cp -r --sparse=never "$O"/images/. /images/
'
mv "$IMAGES/build.log" "$HERE/work/build.log"
cat "$IMAGES/SHA256SUMS"
