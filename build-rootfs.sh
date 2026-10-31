#!/bin/sh
# Build the my355 (Miyoo Flip) rootfs with Buildroot (buildroot/, the
# BR2_EXTERNAL tree; docs/rootfs.md, and docs/rootfs-interface.md for what
# frontends need from it).
#
# Produces, in work/my355:
#   rootfs.tar    glibc, SDL3 under sdl2-compat, libmali, BlueZ, BusyBox,
#                 BaseOS's own tools (src/) and overlay/, with
#                 ./build-kernel.sh's modules and ./build-gpu.sh's Mesa
#   rootfs.json   what it was built from
#   build-id      the build stamped into it, for build-update.sh
#   baseos-my355-sdk.tar.gz
#                 with --sdk: the cross-toolchain and a sysroot of every
#                 library above, to build frontends against (docs/sdk.md)
#
# MY355_DIAG=1 adds overlay-diag/: boot-timing probes, not for release.
#
# The first build makes the toolchain, about an hour; later ones rebuild what
# changed. Output and ccache live in a Docker volume, downloads in work/buildroot/dl.
#
# Usage: ./build-rootfs.sh [--clean] [--sdk] [make target ...]
#   e.g. ./build-rootfs.sh baseos-sdl3-dirclean all
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"

BR_VERSION="2026.08.1"
BR_SHA256="34fb7bea8a213ffde39cc02e61703391560f26e0850f03138c722d0b09880f2b"
BR_URL="https://buildroot.org/downloads/buildroot-$BR_VERSION.tar.xz"
# Rockchip's libmali-next, the branch carrying g29p1 for Bifrost.
LIBMALI_COMMIT="bf621d15f009509557d6b28f81427651695cac20"
LIBMALI_BLOB="lib/aarch64-linux-gnu/libmali-bifrost-g52-g29p1.so"
LIBMALI_BLOB_SHA256="605e3a5caf1be62bb48d97b1168434257355d56db5e3be9b515cfa742c173118"
LIBMALI_GIT="https://github.com/JeffyCN/mirrors.git"

CACHE="$HERE/work/buildroot"
WORK="$HERE/work/my355"
BR_TAR="$CACHE/buildroot-$BR_VERSION.tar.xz"
LIBMALI_SRC="$HERE/work/gpu/libmali-$(printf %.8s "$LIBMALI_COMMIT")"
VOLUME="baseos-buildroot"

CLEAN=0 SDK=0
while :; do
  case "${1:-}" in
    --clean) CLEAN=1; shift ;;
    --sdk) SDK=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
# src/ is a local package, which Buildroot does not watch for changes.
TARGETS="${*:-baseos-tools-rebuild all}"
[ "$SDK" -eq 0 ] || TARGETS="$TARGETS sdk"

DIAG="${MY355_DIAG:-0}"
case "$DIAG" in 0|1) ;; *) echo "MY355_DIAG must be 0 or 1" >&2; exit 1 ;; esac
[ "$DIAG" = 1 ] && echo "== MY355_DIAG=1: adding overlay-diag/ (not for release) =="

baseos_require_prepared "$WORK/prepared"
baseos_require_aarch64
for f in kernel/modules.tar gpu/mesa.tar; do
  [ -f "$WORK/$f" ] || { echo "missing $WORK/$f (run ./build-${f%%/*}.sh)" >&2; exit 1; }
done
mkdir -p "$CACHE/dl"

BASEOS_VERSION="$(baseos_version)"
BASEOS_BUILD="$(git -C "$HERE" describe --always --dirty 2>/dev/null || echo unknown)"
# Two builds of the same uncommitted tree would otherwise share an id, and a card
# skips a same-version payload whose id matches its own.
case "$BASEOS_BUILD" in *-dirty) BASEOS_BUILD="$BASEOS_BUILD-$(date -u +%Y%m%d%H%M%S)" ;; esac
printf '%s\n' "$BASEOS_BUILD" > "$WORK/build-id"

if [ ! -f "$BR_TAR" ] || [ "$(baseos_sha256 "$BR_TAR")" != "$BR_SHA256" ]; then
  echo "== fetching $(basename "$BR_TAR") =="
  curl -fSL --retry 3 -o "$BR_TAR.part" "$BR_URL"
  got="$(baseos_sha256 "$BR_TAR.part")"
  [ "$got" = "$BR_SHA256" ] || { echo "buildroot sha256 is $got, expected $BR_SHA256" >&2
    rm -f "$BR_TAR.part"; exit 1; }
  mv "$BR_TAR.part" "$BR_TAR"
fi

# The branch holds every Rockchip GPU's blobs; check out only the G52's.
if [ ! -f "$LIBMALI_SRC/$LIBMALI_BLOB" ] ||
   [ "$(baseos_sha256 "$LIBMALI_SRC/$LIBMALI_BLOB")" != "$LIBMALI_BLOB_SHA256" ]; then
  echo "== fetching libmali $(printf %.8s "$LIBMALI_COMMIT") =="
  rm -rf "$LIBMALI_SRC"
  git init -q "$LIBMALI_SRC"
  git -C "$LIBMALI_SRC" sparse-checkout set --no-cone '/*' '!/lib/' "/$LIBMALI_BLOB" '!/data/vulkan/lib/arm/'
  git -C "$LIBMALI_SRC" fetch -q --depth 1 --filter=blob:none "$LIBMALI_GIT" "$LIBMALI_COMMIT"
  git -C "$LIBMALI_SRC" checkout -q FETCH_HEAD
  got="$(baseos_sha256 "$LIBMALI_SRC/$LIBMALI_BLOB")"
  [ "$got" = "$LIBMALI_BLOB_SHA256" ] || { echo "libmali blob sha256 is $got" >&2; exit 1; }
fi

[ "$CLEAN" -eq 1 ] && docker volume rm -f "$VOLUME" >/dev/null

echo "== building the rootfs: Buildroot $BR_VERSION, make $TARGETS =="
echo "   log: $WORK/rootfs-build.log"
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$VOLUME":/build -v "$CACHE/dl":/dl -v "$BR_TAR":/buildroot.tar.xz:ro \
  -v "$HERE":/baseos:ro -v "$LIBMALI_SRC":/src/libmali:ro -v "$WORK":/work \
  -e BR_VERSION="$BR_VERSION" -e TARGETS="$TARGETS" -e BASEOS_DIAG="$DIAG" -e SDK="$SDK" \
  -e BASEOS_VERSION="$BASEOS_VERSION" -e BASEOS_BUILD="$BASEOS_BUILD" \
  debian:trixie-slim sh -euc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update >/dev/null
  apt-get -qq install -y --no-install-recommends build-essential file wget cpio unzip \
    rsync bc git ca-certificates python3 perl patch xz-utils bzip2 gzip libncurses-dev cmake \
    >/dev/null
  # Buildroot builds as root in this throwaway container.
  export FORCE_UNSAFE_CONFIGURE=1
  B=/build/buildroot-$BR_VERSION
  [ -d "$B" ] || tar -xJf /buildroot.tar.xz -C /build
  make -C "$B" O=/build/output BR2_EXTERNAL=/baseos/buildroot baseos_my355_defconfig >/dev/null
  # shellcheck disable=SC2086
  if ! make -C "$B" O=/build/output BR2_SDK_PREFIX=baseos-my355-sdk $TARGETS >/work/rootfs-build.log 2>&1; then
    tail -40 /work/rootfs-build.log >&2
    exit 1
  fi
  cp /build/output/images/rootfs.tar /work/rootfs.tar
  if [ "$SDK" = 1 ]; then cp /build/output/images/baseos-my355-sdk.tar.gz /work/; fi
  make -C "$B" O=/build/output -s printvars VARS="%_VERSION" 2>/dev/null |
    sed -n "s/^\([A-Z0-9_]*\)_VERSION=\(.\+\)$/\1 \2/p" | sort > /work/rootfs-versions.txt
'

BR_VERSION="$BR_VERSION" LIBMALI_COMMIT="$LIBMALI_COMMIT" \
ROOTFS_SHA="$(baseos_sha256 "$WORK/rootfs.tar")" \
python3 - "$WORK/rootfs.json" "$WORK/rootfs-versions.txt" <<'EOF'
import json, os, sys
e = os.environ
pkgs = dict(l.split(" ", 1) for l in open(sys.argv[2]).read().splitlines() if " " in l)
json.dump({"buildroot": e["BR_VERSION"], "libmali": e["LIBMALI_COMMIT"],
           "sha256": {"rootfs.tar": e["ROOTFS_SHA"]}, "packages": pkgs},
          open(sys.argv[1], "w"), indent=2)
EOF
rm "$WORK/rootfs-versions.txt"
echo "rootfs: $WORK/rootfs.tar  $(du -h "$WORK/rootfs.tar" | cut -f1)"
