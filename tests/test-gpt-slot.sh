#!/bin/sh
# Offline tests for gptslot against a real tools/mkgpt.py table: geometry
# derivation, flips that move only the entries named, and layouts refused.
# Host-native, no device needed.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

echo "== gptslot =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/src":/src:ro -v "$HERE/tools":/tools:ro \
  alpine:3.20 sh -euc '
  apk add -q build-base linux-headers python3 sgdisk
  gcc -O2 -o /usr/bin/gptslot /src/gptslot.c

  expect() {
    want=$1; shift
    "$@" > /dev/null 2>&1 && got=0 || got=$?
    [ "$got" = "$want" ] || { echo "exit $got, want $want: $*" >&2; exit 1; }
  }

  IMG=/tmp/card.img
  : > "$IMG"
  python3 /tools/mkgpt.py "$IMG" > /dev/null
  eval "$(python3 /tools/mkgpt.py --shell)"
  cp "$IMG" /tmp/fresh.img

  # A freshly built table has every region in its first half.
  eval "$(gptslot "$IMG" geometry)"
  [ "$SLOT_UBOOT" = A ] && [ "$SLOT_BOOT" = A ] && [ "$SLOT_ROOTFS" = A ]
  [ "$SLOT_ROOTFS_ACTIVE" = "$MY355_ROOTFS_START" ]
  [ "$SLOT_ROOTFS_SECTORS" = "$MY355_ROOTFS_SLOT_SECTORS" ]
  [ "$SLOT_ROOTFS_INACTIVE" = $((MY355_ROOTFS_START + MY355_ROOTFS_SLOT_SECTORS)) ]

  # A flip moves the entry named and nothing else, and leaves a valid table.
  gptslot "$IMG" flip rootfs > /dev/null
  sgdisk -v "$IMG" | grep -q "No problems found"
  eval "$(gptslot "$IMG" geometry)"
  [ "$SLOT_ROOTFS" = B ] && [ "$SLOT_UBOOT" = A ] && [ "$SLOT_BOOT" = A ]
  [ "$SLOT_ROOTFS_ACTIVE" = $((MY355_ROOTFS_START + MY355_ROOTFS_SLOT_SECTORS)) ]

  # Two flips restore the card byte for byte.
  gptslot "$IMG" flip rootfs > /dev/null
  cmp "$IMG" /tmp/fresh.img

  # All three commit together, and come back together.
  gptslot "$IMG" flip uboot boot rootfs > /dev/null
  sgdisk -v "$IMG" | grep -q "No problems found"
  eval "$(gptslot "$IMG" geometry)"
  [ "$SLOT_UBOOT" = B ] && [ "$SLOT_BOOT" = B ] && [ "$SLOT_ROOTFS" = B ]
  [ "$SLOT_UBOOT_ACTIVE" = $((MY355_UBOOT_START + MY355_UBOOT_SLOT_SECTORS)) ]
  gptslot "$IMG" flip uboot boot rootfs > /dev/null
  cmp "$IMG" /tmp/fresh.img

  # Only the A/B regions may be flipped, and only known commands run.
  expect 2 gptslot "$IMG" flip data
  expect 2 gptslot "$IMG" flip primary
  expect 2 gptslot "$IMG" flip
  expect 2 gptslot "$IMG" wat
  expect 2 gptslot /tmp/nosuch.img geometry

  # A layout without the reserved halves fails closed: halve rootfs so `data`
  # no longer sits two halves past it, which is the pre-0.3 card shape.
  sgdisk -d 3 -n "3:$MY355_ROOTFS_START:+256M" -c 3:rootfs "$IMG" > /dev/null
  expect 2 gptslot "$IMG" geometry
  expect 2 gptslot "$IMG" flip rootfs

  echo "  PASS derives the halves, flips only what is named, refuses the rest"
'
