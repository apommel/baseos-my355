#!/bin/sh
# Build the rootfs's second GPU stack (docs/mainline-compat.md).
#
# Produces, in work/my355/gpu:
#   mesa.tar      Mesa's Panfrost and PanVK, in usr/lib/mesa
#   gpu.json      what it was built from
#
# The first, Rockchip's libmali, is a Buildroot package (./build-rootfs.sh).
# ./build-rootfs.sh installs both; baseos.conf's gpu= picks one at boot
# (overlay/usr/sbin/baseos-gpu).
#
# Usage: ./build-gpu.sh [--clean]
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"

MESA_VERSION="26.2.5"
MESA_SHA256="794b3d1729075dae7ebd47c7283b7ca0cdb5dec668f7f11cc0a5d82f6138a0a5"
MESA_URL="https://archive.mesa3d.org/mesa-$MESA_VERSION.tar.xz"

CACHE="$HERE/work/gpu"
OUT="$HERE/work/my355/gpu"
MESA_TAR="$CACHE/mesa-$MESA_VERSION.tar.xz"
VOLUME="baseos-gpu-build"

CLEAN=0
case "${1:-}" in
  --clean) CLEAN=1 ;;
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

baseos_require_aarch64
mkdir -p "$CACHE" "$OUT"

if [ ! -f "$MESA_TAR" ] || [ "$(baseos_sha256 "$MESA_TAR")" != "$MESA_SHA256" ]; then
  echo "== fetching $(basename "$MESA_TAR") =="
  curl -fSL --retry 3 -o "$MESA_TAR.part" "$MESA_URL"
  got="$(baseos_sha256 "$MESA_TAR.part")"
  [ "$got" = "$MESA_SHA256" ] || { echo "mesa sha256 is $got, expected $MESA_SHA256" >&2
    rm -f "$MESA_TAR.part"; exit 1; }
  mv "$MESA_TAR.part" "$MESA_TAR"
fi

[ "$CLEAN" -eq 1 ] && docker volume rm -f "$VOLUME" >/dev/null

echo "== building Mesa $MESA_VERSION =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$VOLUME":/build -v "$CACHE":/cache -v "$OUT":/out -e MESA_VERSION="$MESA_VERSION" \
  debian:trixie-slim sh -euc '
  export DEBIAN_FRONTEND=noninteractive
  # Trixie: its glibc and C++ runtime are older than those Buildroot puts in
  # the rootfs, so Mesa runs on them. LLVM, libclc and the SPIR-V tools only
  # build Panfrost precompiled shaders.
  apt-get -qq update >/dev/null
  apt-get -qq install -y --no-install-recommends build-essential pkg-config meson ninja-build \
    python3-mako python3-yaml python3-packaging flex bison xz-utils libdrm-dev \
    libexpat1-dev zlib1g-dev llvm-19-dev libclang-19-dev clang-19 libclc-19 \
    libllvmspirvlib-19-dev llvm-spirv-19 spirv-tools glslang-tools >/dev/null
  export PATH="/usr/lib/llvm-19/bin:$PATH"

  rm -rf /build/stage

  S="/build/mesa-$MESA_VERSION"
  [ -d "$S" ] || tar -xJf "/cache/mesa-$MESA_VERSION.tar.xz" -C /build
  cd "$S"
  # libdir lib/mesa keeps its libEGL and friends beside the libmali ones, and
  # bakes in /usr/lib/mesa as its GBM backend path; the run path finds libgallium.
  # PanVK'"'"'s ICD goes in usr/lib/mesa/vulkan, mounted over libmali'"'"'s.
  # Bundled headers: mesa_clc looks for clang ones beside LLVM, not where Debian has them.
  [ -f b/build.ninja ] || rm -rf b
  [ -d b ] || meson setup b -Dprefix=/usr -Dlibdir=lib/mesa -Dbuildtype=release \
    -Dc_link_args=-Wl,-rpath=/usr/lib/mesa -Dcpp_link_args=-Wl,-rpath=/usr/lib/mesa \
    -Db_ndebug=true -Dplatforms= -Dgallium-drivers=panfrost -Dvulkan-drivers=panfrost \
    -Dvulkan-icd-dir=/usr/lib/mesa/vulkan/icd.d \
    -Dglx=disabled -Degl=enabled -Dgbm=enabled -Dgles1=enabled -Dgles2=enabled \
    -Dopengl=true -Dglvnd=disabled -Dllvm=enabled -Dshared-llvm=enabled -Dmesa-clc-bundle-headers=enabled \
    -Ddraw-use-llvm=false -Dgallium-va=disabled -Dgallium-rusticl=false \
    -Dmicrosoft-clc=disabled -Dvideo-codecs= -Dzstd=disabled -Dvalgrind=disabled \
    -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false -Dtools= \
    >/build/mesa.log
  ninja -C b >>/build/mesa.log
  DESTDIR=/build/stage/mesa ninja -C b install >>/build/mesa.log
  cd /build/stage/mesa
  # The same two names for Mesa: libmali pulls in its EGL, GLES and GBM, so
  # their symbols resolve as libmali'"'"'s did, and the hook only has its marker.
  L=usr/lib/mesa
  echo "int mali_injected;" > /build/hook.c
  echo > /build/empty.c
  gcc -shared -o "$L/libmali_hook.so.1" -Wl,-soname,libmali_hook.so.1 /build/hook.c
  gcc -shared -o "$L/libmali.so.1" -Wl,-soname,libmali.so.1 -Wl,--no-as-needed \
    -Wl,-rpath=/usr/lib/mesa /build/empty.c \
    "$L/libEGL.so.1" "$L/libGLESv2.so.2" "$L/libGLESv1_CM.so.1" "$L/libgbm.so.1"
  rm -rf usr/include usr/lib/mesa/pkgconfig usr/share
  find usr/lib/mesa -name "*.so" -type l -delete
  find /build/stage -name "*.so*" -type f -exec strip --strip-unneeded {} +

  # Newer than the rootfs is fatal: Buildroot builds glibc 2.44 and GCC 15.
  bad=$(find /build/stage -name "*.so*" -type f -exec objdump -T {} + |
    grep -o -E "GLIBC_2\.(4[5-9]|[5-9][0-9])|GLIBCXX_3\.4\.(3[5-9])" | sort -u)
  [ -z "$bad" ] || { echo "needs newer than the rootfs: $bad" >&2; exit 1; }
  ! find /build/stage -name "*.so*" -type f -exec readelf -d {} + | grep -q "NEEDED.*LLVM" ||
    { echo "Mesa links LLVM at runtime" >&2; exit 1; }

  tar -cf /out/mesa.tar -C /build/stage/mesa usr
  tar -tvf /out/mesa.tar | sed "s/^/  /"
'

MESA_VERSION="$MESA_VERSION" MESA_SHA="$(baseos_sha256 "$OUT/mesa.tar")" \
python3 - "$OUT/gpu.json" <<'EOF'
import json, os, sys
e = os.environ
json.dump({"mesa": e["MESA_VERSION"], "sha256": {"mesa.tar": e["MESA_SHA"]}},
          open(sys.argv[1], "w"), indent=2)
EOF

echo
echo "  $OUT"
