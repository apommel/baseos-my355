#!/bin/sh
# The real payload against a copy of the real image: the reserved halves receive
# exactly the payload bytes, the GPT commits, the new rootfs is mountable and
# carries the new version, and `data` and `primary` come through untouched.
# Needs ./build-image.sh and ./build-update.sh to have run.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

WORK="$HERE/work/my355"
VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
PAYLOAD="$WORK/baseos-my355-$VERSION.bosupd"
for f in "$WORK/baseos-my355.img" "$PAYLOAD"; do
  [ -f "$f" ] || { echo "missing $f (run ./build-image.sh && ./build-update.sh)" >&2; exit 1; }
done

echo "== update round trip =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$WORK":/work:ro -v "$HERE/src":/src:ro -v "$HERE/tools":/tools:ro \
  -v "$HERE/overlay/usr/sbin/baseos-update":/test/baseos-update:ro \
  -e VERSION="$VERSION" \
  alpine:3.20 sh -euc '
  apk add -q build-base linux-headers python3 e2fsprogs e2fsprogs-extra
  gcc -O2 -o /usr/sbin/gptslot /src/gptslot.c

  stub() { rm -f "$1"; printf "#!/bin/sh\n%s\n" "$2" > "$1"; chmod +x "$1"; }
  stub /usr/bin/baseos-splash ":"
  stub /sbin/reboot ":"
  stub /bin/sleep ":"
  stub /bin/sync ":"

  eval "$(python3 /tools/mkgpt.py --shell)"
  slice() { dd if=/tmp/card.img bs=512 skip="$1" count="$2" status=none | sha256sum; }

  cp /work/baseos-my355.img /tmp/card.img
  ln -sf /tmp/card.img /dev/mmcblk1
  mkdir -p /mnt/SDCARD /data
  cp "/work/baseos-my355-$VERSION.bosupd" /mnt/SDCARD/
  # An older running version, so the payload is an upgrade.
  printf "BASEOS_TARGET=my355\nBASEOS_VERSION=0.0.1\nBASEOS_BUILD=old\n" > /etc/baseos-release

  before_data="$(slice "$MY355_DATA_START" "$MY355_DATA_SECTORS")"
  before_primary="$(slice "$MY355_PRIMARY_START" "$MY355_PRIMARY_SECTORS")"

  sh /test/baseos-update apply

  # Every region now runs from its second half.
  eval "$(gptslot /dev/mmcblk1 geometry)"
  [ "$SLOT_UBOOT" = B ] && [ "$SLOT_BOOT" = B ] && [ "$SLOT_ROOTFS" = B ]

  # What is in them is what the payload declared.
  for region in uboot boot rootfs; do
    eval "start=\$SLOT_$(echo "$region" | tr a-z A-Z)_ACTIVE"
    eval "count=\$SLOT_$(echo "$region" | tr a-z A-Z)_SECTORS"
    want="$(sed -n "s/^$region-sha256=//p" /tmp/.bosupd-manifest)"
    [ "$(slice "$start" "$count" | cut -d\  -f1)" = "$want" ] || {
      echo "$region does not match the payload" >&2; exit 1; }
  done

  # The partitions holding user files are exactly as they were.
  [ "$(slice "$MY355_DATA_START" "$MY355_DATA_SECTORS")" = "$before_data" ]
  [ "$(slice "$MY355_PRIMARY_START" "$MY355_PRIMARY_SECTORS")" = "$before_primary" ]

  # The new rootfs is a filesystem, and it is the one we built.
  dd if=/tmp/card.img of=/tmp/new-rootfs.img bs=512 skip="$SLOT_ROOTFS_ACTIVE" \
     count="$SLOT_ROOTFS_SECTORS" status=none
  e2fsck -fn /tmp/new-rootfs.img > /dev/null 2>&1
  debugfs -R "cat /etc/baseos-release" /tmp/new-rootfs.img 2>/dev/null \
    | grep -qx "BASEOS_VERSION=$VERSION"

  grep -q "^$(sed -n "s/^rootfs-sha256=//p" /tmp/.bosupd-manifest) " /data/update/history

  echo "  PASS the halves take the payload, data and primary are untouched"
'
