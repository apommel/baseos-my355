#!/bin/sh
# Offline tests for the first-boot card expansion: gptgrow against a real GPT,
# and expand-storage against stubs. Runs in a container; no device needed.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"

echo "== gptgrow =="
docker run --rm \
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
docker run --rm \
  -v "$HERE/board/my355/rootfs-overlay/usr/sbin/expand-storage":/test/expand-storage:ro \
  -v "$HERE/board/my355/rootfs-overlay/usr/share/baseos/log.sh":/usr/share/baseos/log.sh:ro \
  --tmpfs /data \
  alpine:3.20 sh -euc '
  mknod /dev/mmcblk1 b 7 0
  mknod /dev/mmcblk1p5 b 7 1
  for f in cp mkdir rm sync touch; do [ -e /bin/$f ] || ln -s "$(which $f)" /bin/$f; done
  mkdir -p /usr/share/baseos
  echo readme > /usr/share/baseos/card-readme.txt
  echo conf > /usr/share/baseos/baseos.conf

  stub() { rm -f "$1"; printf "%s\n" "#!/bin/sh" "$2" > "$1"; chmod 755 "$1"; }
  stub /usr/bin/baseos-splash "echo \"\$*\" >> /tmp/splash.log"
  # mkfs empties the mount point, as a format would.
  stub /bin/mount "mkdir -p /tmp/.primary"
  stub /bin/umount "exit 0"
  stub /usr/sbin/mkfs.exfat "echo \"\$*\" >> /tmp/mkfs.log; rm -rf /tmp/.primary"

  reset() {
    rm -rf /tmp/splash.log /tmp/mkfs.log /tmp/ran /tmp/.primary /data/*
    # Where stock leaves the backup and log of the preloader installer.
    echo original > /data/mtd5-original-abc.img
    echo log > /data/baseos-preloader.log
  }

  # An expanded card: nothing runs at all, not even gptgrow.
  reset; touch /data/expanded
  stub /usr/sbin/gptgrow "touch /tmp/ran"
  sh /test/expand-storage
  [ ! -e /tmp/ran ] || { echo "gptgrow ran on an expanded card" >&2; exit 1; }

  # Already full and not grown by us: leave it alone.
  reset
  stub /usr/sbin/gptgrow "exit 1"
  sh /test/expand-storage
  [ ! -e /tmp/mkfs.log ] || { echo "reformatted an unknown card" >&2; exit 1; }
  [ ! -e /tmp/splash.log ] || { echo "painted for a card it left alone" >&2; exit 1; }
  [ -e /data/expanded ] && [ -e /data/mtd5-original-abc.img ]

  # First boot: one mkfs, the volume filled, the installer files moved.
  reset
  stub /usr/sbin/gptgrow "exit 0"
  sh /test/expand-storage
  [ "$(tail -1 /tmp/splash.log)" = "--important 100 EXPANDING STORAGE" ]
  grep -qx -- "-L BASEOS /dev/mmcblk1p5" /tmp/mkfs.log
  grep -qx readme /tmp/.primary/README.txt
  grep -qx conf /tmp/.primary/baseos.conf
  grep -qx original /tmp/.primary/mtd5-original-abc.img
  grep -qx log /tmp/.primary/baseos-preloader.log
  [ ! -e /data/mtd5-original-abc.img ] && [ ! -e /data/baseos-preloader.log ]
  [ -e /data/expanded ] && [ ! -e /data/expand-grown ]

  # A gptgrow error touches nothing.
  reset
  stub /usr/sbin/gptgrow "exit 2"
  if sh /test/expand-storage; then echo "gptgrow failure must propagate" >&2; exit 1; fi
  [ ! -e /tmp/mkfs.log ] || { echo "formatted after a gptgrow error" >&2; exit 1; }

  # Power cut after the grow: the next boot formats although the card is full.
  reset; touch /data/expand-grown
  stub /usr/sbin/gptgrow "exit 1"
  sh /test/expand-storage
  grep -qx original /tmp/.primary/mtd5-original-abc.img
  [ -e /data/expanded ]

  # A failed copy keeps the backup on /data.
  reset
  stub /usr/sbin/gptgrow "exit 0"
  stub /usr/sbin/mkfs.exfat "rm -rf /tmp/.primary; mkdir -p /tmp/.primary/mtd5-original-abc.img/x"
  sh /test/expand-storage
  grep -qx original /data/mtd5-original-abc.img

  echo "  PASS expands once, moves the installer files, resumes after a power cut"
'
