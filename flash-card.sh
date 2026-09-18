#!/bin/sh
# Write the built image to an SD card, on macOS.
# Usage: ./flash-card.sh          list the candidate disks
#        ./flash-card.sh diskN    write work/my355/baseos-my355.img to diskN
#
# Refuses anything that is not physical removable media — an SD slot or card
# reader — or is smaller than the image, and asks for the disk name to be typed
# back before writing. Elsewhere, any image writer works (INSTALL.md).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
IMG="$HERE/work/my355/baseos-my355.img"

command -v diskutil >/dev/null 2>&1 || {
  echo "flash-card.sh is macOS-only; use any image writer (INSTALL.md)" >&2; exit 1; }
[ -f "$IMG" ] || { echo "missing $IMG (run ./build-all.sh)" >&2; exit 1; }
IMG_BYTES=$(stat -f %z "$IMG")

if [ "$#" -eq 0 ]; then
  echo "Removable candidates:"
  diskutil list external physical || true
  echo
  echo "Usage: $0 diskN"
  exit 0
fi
[ "$#" -eq 1 ] || { echo "usage: $0 [diskN]" >&2; exit 2; }

DISK="$1"
case "$DISK" in
  disk[0-9]|disk[0-9][0-9]) ;;
  *) echo "expected a whole disk such as disk4, got '$DISK'" >&2; exit 2 ;;
esac

INFO="$(diskutil info "$DISK")"
field() { printf '%s\n' "$INFO" | sed -n "s/^ *$1: *//p" | head -1; }

# A mounted disk image reports itself as external and removable; only this
# tells it apart from a card.
[ "$(field Virtual)" != Yes ] || { echo "REFUSING: $DISK is a disk image, not a card" >&2; exit 1; }
# Internal and external SSDs alike are Fixed; SD slots and card readers are not.
[ "$(field 'Removable Media')" = Removable ] || {
  echo "REFUSING: $DISK is not removable media" >&2; exit 1; }

DISK_BYTES=$(field 'Disk Size' | sed -n 's/.*(\([0-9]*\) Bytes).*/\1/p')
[ -n "$DISK_BYTES" ] || { echo "cannot determine the size of $DISK" >&2; exit 1; }
[ "$DISK_BYTES" -ge "$IMG_BYTES" ] || {
  echo "REFUSING: $DISK ($DISK_BYTES bytes) is smaller than the image ($IMG_BYTES bytes)" >&2
  exit 1; }

printf '%s\n' "$INFO" | grep -E "Device Node|Media Name|Disk Size|Protocol|Device Location"
echo "Image: $IMG"
echo
printf "This DESTROYS everything on /dev/%s. Type '%s' to continue: " "$DISK" "$DISK"
read -r CONFIRM || CONFIRM=""
[ "$CONFIRM" = "$DISK" ] || { echo "aborted"; exit 1; }

diskutil unmountDisk "/dev/$DISK"
# The raw node: the buffered /dev/diskN is several times slower.
sudo dd if="$IMG" of="/dev/r$DISK" bs=4m status=progress
sync
diskutil eject "/dev/$DISK" || true
echo "Done. Put the card in the Flip's right-hand slot and power on (INSTALL.md)."
