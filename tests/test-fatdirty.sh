#!/bin/sh
# Offline tests for fatdirty against real mkfs images: the flag found at the
# offset Linux reads for each FAT type, volumes that are not FAT refused, and
# fsck.fat -a clearing what fatdirty reports. Runs in a container; no device.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/common.sh
. "$HERE/tools/common.sh"

echo "== fatdirty =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/src":/src:ro alpine:3.20 sh -euc '
  apk add -q build-base linux-headers dosfstools exfatprogs
  gcc -O2 -Wall -Wextra -Werror -o /usr/bin/fatdirty /src/fatdirty.c

  expect() {
    want=$1; shift
    "$@" > /dev/null 2>&1 && got=0 || got=$?
    [ "$got" = "$want" ] || { echo "exit $got, want $want: $*" >&2; exit 1; }
  }
  # Sets bit 0 of the byte at $2, as Linux does at mount.
  dirty() { printf "\001" | dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null; }

  cd /tmp
  truncate -s 64M f32.img; mkfs.fat -F 32 f32.img > /dev/null
  truncate -s 32M f16.img; mkfs.fat -F 16 f16.img > /dev/null
  truncate -s 4M  f12.img; mkfs.fat -F 12 f12.img > /dev/null
  expect 1 fatdirty f32.img
  expect 1 fatdirty f16.img
  expect 1 fatdirty f12.img

  # FAT32 keeps the flag at 65, FAT12/16 at 37; the other offset means nothing.
  cp f32.img d32.img; dirty d32.img 65; expect 0 fatdirty d32.img
  cp f16.img d16.img; dirty d16.img 37; expect 0 fatdirty d16.img
  cp f12.img d12.img; dirty d12.img 37; expect 0 fatdirty d12.img
  cp f32.img x32.img; dirty x32.img 37; expect 1 fatdirty x32.img
  cp f16.img x16.img; dirty x16.img 65; expect 1 fatdirty x16.img

  # A dirty volume prints the size of its FATs in sectors, as fsck.fat sees it.
  for f in d32 d16 d12; do
    per=$(fsck.fat -n -v "$f.img" | sed -n "s/^ *\([0-9]*\) bytes per FAT.*/\1/p")
    got=$(fatdirty "$f.img" || :)
    [ "$got" = $((2 * per / 512)) ] || { echo "$f.img: fatdirty $got, want $((2 * per / 512))" >&2; exit 1; }
  done

  # fsck.fat -a clears it: exit 0 or 1, both meaning the volume is now sound.
  for f in d32 d16 d12; do
    fsck.fat -a "$f.img" > /dev/null && rc=0 || rc=$?
    [ "$rc" -le 1 ] || { echo "fsck.fat -a $f.img exited $rc" >&2; exit 1; }
    expect 1 fatdirty "$f.img"
  done

  # Not FAT, even where offset 65 happens to be odd.
  truncate -s 64M ex.img; mkfs.exfat ex.img > /dev/null
  dirty ex.img 65; expect 2 fatdirty ex.img
  head -c 512 /dev/zero > zero.img; dirty zero.img 65; expect 2 fatdirty zero.img
  cp d32.img nosig.img; printf "\000\000" | dd of=nosig.img bs=1 seek=510 conv=notrunc 2>/dev/null
  dirty nosig.img 65; expect 2 fatdirty nosig.img
  head -c 100 f32.img > short.img; expect 2 fatdirty short.img
  expect 2 fatdirty /nonexistent
  expect 2 fatdirty
  expect 2 fatdirty f32.img f16.img
  echo "  ok"
'
