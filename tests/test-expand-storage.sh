#!/bin/sh
# Offline tests for the first-boot card expansion: gptgrow against a real GPT,
# and expand-storage against stubs. Host-native, no device needed.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

echo "== gptgrow =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/src":/src:ro -v "$HERE/tools":/tools:ro \
  alpine:3.20 sh -euc '
  apk add -q build-base linux-headers python3 sgdisk
  gcc -O2 -o /usr/bin/gptgrow /src/gptgrow.c

  expect() {
    want=$1; shift
    "$@" > /dev/null 2>&1 && got=0 || got=$?
    [ "$got" = "$want" ] || { echo "exit $got, want $want: $*" >&2; exit 1; }
  }

  IMG=/tmp/card.img
  : > "$IMG"
  python3 /tools/mkgpt.py "$IMG" > /dev/null
  truncate -s 20G "$IMG"          # as if flashed to a 20 GB card
  LAST=$((20 * 1024 * 1024 * 1024 / 512 - 34))

  expect 0 gptgrow "$IMG" primary
  sgdisk -v "$IMG" | grep -q "No problems found"
  sgdisk -i 5 "$IMG" | grep -q "Microsoft basic data"
  END=$(sgdisk -i 5 "$IMG" | sed -n "s/.*Last sector: \([0-9]*\).*/\1/p")
  [ "$END" = "$LAST" ] || { echo "p5 ends at $END, want $LAST" >&2; exit 1; }

  expect 1 gptgrow "$IMG" primary     # idempotent
  expect 2 gptgrow "$IMG" rootfs      # not MS basic data
  expect 2 gptgrow "$IMG" nosuch

  echo "  PASS grows to the end of the device, idempotent, refuses other entries"
'

echo "== expand-storage =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/overlay/usr/sbin/expand-storage":/test/expand-storage:ro \
  alpine:3.20 sh -euc '
  mknod /dev/mmcblk1 b 7 0
  mknod /dev/mmcblk1p5 b 7 1
  mkdir -p /data
  for f in cut cp mkdir mv rm sync touch; do [ -e /bin/$f ] || ln -s "$(which $f)" /bin/$f; done

  stub() { rm -f "$1"; printf "%s\n" "#!/bin/sh" "$2" > "$1"; chmod 755 "$1"; }
  stub /usr/bin/baseos-splash "echo \"\$*\" >> /tmp/splash.log"
  # mount(8) leaves the mount point alone; mkfs wipes it, as the real one does,
  # so a restored file proves staging worked.
  stub /bin/mount "for a; do d=\$a; done; mkdir -p \"\$d\""
  stub /bin/umount "exit 0"
  stub /sbin/mkfs.vfat "echo \"\$*\" >> /tmp/mkfs.log; rm -rf /tmp/.primary/*"

  reset() {
    rm -rf /tmp/splash.log /tmp/mkfs.log /tmp/ran /tmp/.primary /data/expanded /data/expand-stage
    mkdir -p /tmp/.primary
    echo original > /tmp/.primary/mtd5-original-abc.img
  }

  # An expanded card: nothing runs at all, not even gptgrow.
  reset; touch /data/expanded
  stub /usr/sbin/gptgrow "touch /tmp/ran"
  sh /test/expand-storage
  [ ! -e /tmp/ran ] || { echo "gptgrow ran on an expanded card" >&2; exit 1; }

  # Already full with nothing staged: not a card we grew, leave it alone.
  reset
  stub /usr/sbin/gptgrow "exit 1"
  sh /test/expand-storage
  [ ! -e /tmp/mkfs.log ] || { echo "reformatted an unknown card" >&2; exit 1; }
  [ ! -e /tmp/splash.log ] || { echo "painted for a card it left alone" >&2; exit 1; }
  [ -e /data/expanded ]

  # First boot: the track runs 45 -> 100, one mkfs, card contents preserved.
  reset
  stub /usr/sbin/gptgrow "exit 0"
  sh /test/expand-storage
  [ "$(head -1 /tmp/splash.log)" = "--important 45 EXPANDING STORAGE" ]
  [ "$(tail -1 /tmp/splash.log)" = "--important 100 EXPANDING STORAGE" ]
  grep -qx -- "-n BASEOS /dev/mmcblk1p5" /tmp/mkfs.log
  grep -qx original /tmp/.primary/mtd5-original-abc.img
  [ -e /data/expanded ] && [ ! -d /data/expand-stage ]

  # A gptgrow error touches nothing.
  reset
  stub /usr/sbin/gptgrow "exit 2"
  if sh /test/expand-storage; then echo "gptgrow failure must propagate" >&2; exit 1; fi
  [ ! -e /tmp/mkfs.log ] || { echo "formatted after a gptgrow error" >&2; exit 1; }

  # Power cut after staging: the card is already full and the staged contents
  # are restored on the next boot.
  reset
  mkdir -p /data/expand-stage; echo original > /data/expand-stage/mtd5-original-abc.img
  rm -f /tmp/.primary/mtd5-original-abc.img
  stub /usr/sbin/gptgrow "exit 1"
  sh /test/expand-storage
  grep -qx original /tmp/.primary/mtd5-original-abc.img
  [ -e /data/expanded ]

  echo "  PASS expands once, finishes the track, resumes after a power cut"
'
