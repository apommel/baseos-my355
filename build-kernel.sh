#!/bin/sh
# Build the mainline Linux kernel for my355 (experimental; docs/mainline-compat.md).
#
# Produces, in work/my355/kernel:
#   Image                    the arm64 kernel, uncompressed (mkfit.py compresses)
#   rk3566-miyoo-flip.dtb    from tools/kernel/dts
#   modules.tar              lib/modules/<release>, with the out-of-tree
#                            mali_kbase and 8733bu under extra/ and depmod
#                            already run
#   kernel.json              what it was built with; build-image.sh checks it
#
# Patches and drivers sit in hardware/ (the board on mainline, upstreamable)
# or stock/ (the vendor kernel's interface on top, BaseOS-only).
#
# Then: MY355_KERNEL=mainline ./build-rootfs.sh && MY355_KERNEL=mainline ./build-image.sh
#
# Usage: ./build-kernel.sh [--clean]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"

LINUX_VERSION="7.2.10"
LINUX_SHA256="2feaa70453e91f541be6a5c9078d8168e081af45a3d9718054850538cff2ebf3"
LINUX_URL="https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$LINUX_VERSION.tar.xz"
# ROCKNIX's kbase (r54p2, UK 11.46), the pin known to build against 7.2.
KBASE_COMMIT="39da994bb6fc8819e5e8c1873907dd21d17e53c1"
KBASE_SHA256="f947b99a1bcb5b86ea270c1ce4cd189f4df26b3c0c8ba92c1ef256bb757afa66"
KBASE_URL="https://github.com/rocknix/mali_kbase/archive/$KBASE_COMMIT.tar.gz"
# The RTL8733BU's WiFi half, zlyme's pin: its next commit needs a 7.1-only API.
RTL_COMMIT="c46aa25e237cb43f33390cf58eee5c69d9b32883"
RTL_SHA256="6180121a428c172420e307735fb0a6ee6fad2895dd979d3f487d703e398a6e45"
RTL_URL="https://github.com/Charliechen114514/rtl8733bu-linux-driver/archive/$RTL_COMMIT.tar.gz"

CACHE="$HERE/work/kernel"
OUT="$HERE/work/my355/kernel"
LINUX_TAR="$CACHE/linux-$LINUX_VERSION.tar.xz"
KBASE_TAR="$CACHE/mali_kbase-$(printf %.8s "$KBASE_COMMIT").tar.gz"
RTL_TAR="$CACHE/rtl8733bu-$(printf %.8s "$RTL_COMMIT").tar.gz"
# The tree lives in a Docker volume: Linux has paths differing only in case,
# which a macOS bind mount would merge.
VOLUME="baseos-kernel-build"

CLEAN=0
case "${1:-}" in
  --clean) CLEAN=1 ;;
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

fetch() { # url file sha256
  if [ ! -f "$2" ] || [ "$(baseos_sha256 "$2")" != "$3" ]; then
    echo "== fetching $(basename "$2") =="
    curl -fSL --retry 3 -o "$2.part" "$1"
    got="$(baseos_sha256 "$2.part")"
    [ "$got" = "$3" ] || { echo "$(basename "$2") sha256 is $got, expected $3" >&2
      rm -f "$2.part"; exit 1; }
    mv "$2.part" "$2"
  fi
}
mkdir -p "$CACHE" "$OUT"
fetch "$LINUX_URL" "$LINUX_TAR" "$LINUX_SHA256"
fetch "$KBASE_URL" "$KBASE_TAR" "$KBASE_SHA256"
fetch "$RTL_URL" "$RTL_TAR" "$RTL_SHA256"

[ "$CLEAN" -eq 1 ] && docker volume rm -f "$VOLUME" >/dev/null
# A changed patch set must force a fresh extraction, or it would silently be
# missing from the build.
(cd "$HERE/tools/kernel" && cat patches/hardware/*.patch patches/stock/*.patch mali_kbase/*.patch rtl8733bu/*.patch) \
  > "$CACHE/patches.cat"
PATCH_SUM="$(baseos_sha256 "$CACHE/patches.cat")"

echo "== building Linux $LINUX_VERSION for my355 =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$VOLUME":/build -v "$CACHE":/cache -v "$HERE/tools/kernel":/kernel:ro \
  -e LINUX_VERSION="$LINUX_VERSION" -e KBASE_COMMIT="$KBASE_COMMIT" \
  -e RTL_COMMIT="$RTL_COMMIT" \
  -e LINUX_TAR="$(basename "$LINUX_TAR")" -e KBASE_TAR="$(basename "$KBASE_TAR")" \
  -e RTL_TAR="$(basename "$RTL_TAR")" \
  -e PATCH_SUM="$PATCH_SUM" \
  debian:bookworm-slim sh -euc '
  export DEBIAN_FRONTEND=noninteractive
  # An arm64 host builds natively; anything else cross-compiles.
  if [ "$(uname -m)" = aarch64 ]; then CC_PKG=gcc; CROSS=; else
    CC_PKG=gcc-aarch64-linux-gnu; CROSS=aarch64-linux-gnu-; fi
  apt-get -qq update
  apt-get -qq install -y --no-install-recommends \
    build-essential bc bison flex libssl-dev libelf-dev patch python3 \
    device-tree-compiler kmod cpio xz-utils "$CC_PKG" >/dev/null

  SRC="/build/linux-$LINUX_VERSION"
  KB="/build/mali_kbase-$KBASE_COMMIT"
  RTL="/build/rtl8733bu-linux-driver-$RTL_COMMIT"
  if [ "$(cat /build/patches.sha256 2>/dev/null || true)" != "$PATCH_SUM" ] ||
     [ ! -d "$RTL" ]; then
    rm -rf "$SRC" "$KB" "$RTL" /build/patches.sha256
    tar -xJf "/cache/$LINUX_TAR" -C /build
    tar -xzf "/cache/$KBASE_TAR" -C /build
    tar -xzf "/cache/$RTL_TAR" -C /build
    for p in /kernel/patches/hardware/*.patch /kernel/patches/stock/*.patch; do
      echo "  patch: ${p#/kernel/patches/}"
      patch -p1 -d "$SRC" --batch --forward --quiet < "$p"
    done
    for p in /kernel/mali_kbase/*.patch; do
      echo "  patch: mali_kbase/$(basename "$p")"
      patch -p1 -d "$KB" --batch --forward --quiet < "$p"
    done
    for p in /kernel/rtl8733bu/*.patch; do
      echo "  patch: rtl8733bu/$(basename "$p")"
      patch -p1 -d "$RTL" --batch --forward --quiet < "$p"
    done
    echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += rk3566-miyoo-flip.dtb" \
      >> "$SRC/arch/arm64/boot/dts/rockchip/Makefile"
    echo "$PATCH_SUM" > /build/patches.sha256
  fi
  cd "$SRC"
  # Our drivers: copied every build, not patched in once, so an edit is always
  # picked up; the Kconfig symbol is added once.
  driver() { # file dir symbol type prompt depends
    cp "/kernel/drivers/$1" "$2/"
    grep -q "^config $3\$" "$2/Kconfig" && return
    printf "\nconfig %s\n\t%s \"%s\"\n\tdepends on %s\n" "$3" "$4" "$5" "$6" >> "$2/Kconfig"
    echo "obj-\$(CONFIG_$3) += $(basename "$1" .c).o" >> "$2/Makefile"
  }
  driver hardware/panel-generic-dsi.c drivers/gpu/drm/panel DRM_PANEL_GENERIC_DSI tristate \
    "Generic MIPI DSI panel described in the device tree" \
    "DRM_PANEL && OF && DRM_MIPI_DSI && BACKLIGHT_CLASS_DEVICE"
  driver hardware/miyoo-player1.c drivers/input/joystick JOYSTICK_MIYOO_PLAYER1 tristate \
    "Miyoo Flip gamepad, presented as MIYOO Player1" \
    "INPUT_JOYSTICK && SERIAL_DEV_BUS && GPIOLIB && OF"
  driver hardware/rockchip-pm-config.c drivers/soc/rockchip ROCKCHIP_PM_CONFIG bool \
    "Rockchip RK3568 BL31 suspend configuration" \
    "ARCH_ROCKCHIP && HAVE_ARM_SMCCC && OF && SUSPEND"
  driver stock/hall-mh248.c drivers/input/misc INPUT_HALL_MH248 tristate \
    "Miyoo Flip lid sensor, as hall-mh248" "INPUT_MISC && GPIOLIB && OF"
  driver stock/rkwifi.c drivers/misc MISC_RKWIFI tristate \
    "Stock rkwifi wifi_power, over a regulator" "REGULATOR && OF"
  driver stock/rtk_btusb.c drivers/bluetooth BT_RTK_BTUSB_SHIM tristate \
    "Stock rtk_btusb, loading btusb" "BT_HCIBTUSB"
  cp /kernel/dts/*.dts arch/arm64/boot/dts/rockchip/

  export ARCH=arm64 CROSS_COMPILE="$CROSS"
  # Same inputs, same kernel.
  export KBUILD_BUILD_TIMESTAMP="@0" KBUILD_BUILD_USER=baseos KBUILD_BUILD_HOST=baseos

  make defconfig >/dev/null
  ./scripts/kconfig/merge_config.sh -m -O . .config /kernel/my355.config >/dev/null
  make olddefconfig >/dev/null

  # Kconfig drops a fragment line silently (a `select`, a `depends on`).
  fail=0
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
  done < /kernel/my355.config
  [ "$fail" -eq 0 ] || { echo "config assertions failed" >&2; exit 1; }
  echo "  config: every fragment line survived olddefconfig"

  make -j"$(nproc)" Image modules rockchip/rk3566-miyoo-flip.dtb >/dev/null
  KREL=$(make -s kernelrelease)

  make -j"$(nproc)" -C "$SRC" M="$KB/product/kernel/drivers/gpu/arm/midgard" \
    CONFIG_MALI_MIDGARD=m CONFIG_MALI_PLATFORM_NAME=devicetree \
    CONFIG_MALI_REAL_HW=y CONFIG_MALI_DEVFREQ=y modules >/dev/null
  make -j"$(nproc)" -C "$SRC" M="$RTL" CONFIG_RTL8733BU=m modules >/dev/null

  STAGE=/build/stage
  rm -rf "$STAGE"
  make INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 DEPMOD=/bin/true \
    modules_install >/dev/null
  make -C "$SRC" M="$KB/product/kernel/drivers/gpu/arm/midgard" \
    INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 INSTALL_MOD_DIR=extra DEPMOD=/bin/true \
    modules_install >/dev/null
  make -C "$SRC" M="$RTL" CONFIG_RTL8733BU=m \
    INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 INSTALL_MOD_DIR=extra DEPMOD=/bin/true \
    modules_install >/dev/null
  # The build and source links point into this container.
  rm -f "$STAGE/lib/modules/$KREL/build" "$STAGE/lib/modules/$KREL/source"
  depmod -b "$STAGE" "$KREL"
  for m in mali_kbase 8733bu; do
    test -f "$STAGE/lib/modules/$KREL/extra/$m.ko" || {
      echo "$m.ko was not built" >&2; exit 1; }
  done

  # cat, not cp: cp punches holes, which a macOS bind mount refuses.
  cat arch/arm64/boot/Image > /cache/Image
  cat arch/arm64/boot/dts/rockchip/rk3566-miyoo-flip.dtb > /cache/rk3566-miyoo-flip.dtb
  tar -C "$STAGE" --sort=name --mtime=@0 --owner=0 --group=0 -cf /cache/modules.tar lib/modules
  echo "$KREL" > /cache/kernelrelease
  echo "  $KREL: Image $(stat -c %s /cache/Image) bytes, $(find "$STAGE" -name "*.ko" | wc -l) modules"
'

for f in Image rk3566-miyoo-flip.dtb modules.tar; do mv "$CACHE/$f" "$OUT/$f"; done
KREL="$(cat "$CACHE/kernelrelease")"

KREL="$KREL" LINUX_VERSION="$LINUX_VERSION" KBASE_COMMIT="$KBASE_COMMIT" RTL_COMMIT="$RTL_COMMIT" \
IMAGE_SHA="$(baseos_sha256 "$OUT/Image")" DTB_SHA="$(baseos_sha256 "$OUT/rk3566-miyoo-flip.dtb")" \
MODULES_SHA="$(baseos_sha256 "$OUT/modules.tar")" \
python3 - "$OUT/kernel.json" <<'EOF'
import json, os, sys
e = os.environ
json.dump({"linux_version": e["LINUX_VERSION"], "kernelrelease": e["KREL"],
           "mali_kbase": e["KBASE_COMMIT"], "rtl8733bu": e["RTL_COMMIT"],
           "sha256": {"Image": e["IMAGE_SHA"], "rk3566-miyoo-flip.dtb": e["DTB_SHA"],
                      "modules.tar": e["MODULES_SHA"]}},
          open(sys.argv[1], "w"), indent=2)
EOF

echo
echo "  $OUT ($KREL)"
echo "  next: MY355_KERNEL=mainline ./build-rootfs.sh && MY355_KERNEL=mainline ./build-image.sh"
