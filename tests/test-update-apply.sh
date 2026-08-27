#!/bin/sh
# Offline tests for baseos-update: the engine on stubs, with 1 MiB slots so a
# whole round trip costs 3 MiB. Host-native, no device needed.
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

echo "== baseos-update =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/overlay/usr/sbin/baseos-update":/test/baseos-update:ro \
  alpine:3.20 sh -euc '
  apk add -q python3

  stub() {
    path=$1; shift
    rm -f "$path"
    printf "#!/bin/sh\n%s\n" "$*" > "$path"
    chmod +x "$path"
  }

  # 1 MiB halves: uboot 0/1, boot 2/3, rootfs 4/5, in MiB into the disk.
  stub /usr/sbin/gptslot "
    case \$2 in
    geometry) echo SLOT_UBOOT=A; echo SLOT_UBOOT_SECTORS=2048
              echo SLOT_UBOOT_ACTIVE=0; echo SLOT_UBOOT_INACTIVE=2048
              echo SLOT_BOOT=A; echo SLOT_BOOT_SECTORS=2048
              echo SLOT_BOOT_ACTIVE=4096; echo SLOT_BOOT_INACTIVE=6144
              echo SLOT_ROOTFS=A; echo SLOT_ROOTFS_SECTORS=2048
              echo SLOT_ROOTFS_ACTIVE=8192; echo SLOT_ROOTFS_INACTIVE=10240 ;;
    flip) shift 2; echo \"\$*\" >> /tmp/flip.log ;;
    esac"
  stub /usr/bin/baseos-splash "echo \"\$*\" >> /tmp/splash.log"
  stub /sbin/reboot "echo rebooted >> /tmp/reboot.log"
  # apply() holds rcS with a sleep after asking for the reboot init will do.
  stub /bin/sleep ":"
  stub /bin/sync ":"

  mkdir -p /mnt/SDCARD /data
  printf "BASEOS_TARGET=my355\nBASEOS_VERSION=0.3.0\nBASEOS_BUILD=abc\n" \
    > /etc/baseos-release

  cat > /mkpayload.py <<"PY"
import gzip, hashlib, io, sys, tarfile
out, target, version, build = sys.argv[1:5]
flaw = sys.argv[5] if len(sys.argv) > 5 else ""
sectors = 4096 if flaw == "badslots" else 2048
fields = [("format", "baseos-update/2"), ("target", target),
          ("version", version), ("build", build)]
members = []
for i, name in enumerate(("uboot", "boot", "rootfs")):
    body = bytes([0x40 + i]) * (2048 * 512)
    open("/tmp/expect-" + name + ".bin", "wb").write(body)
    sha = hashlib.sha256(body).hexdigest()
    if flaw == "corrupt" and name == "rootfs":
        sha = "0" * 64
    fields += [(name + "-sectors", sectors), (name + "-sha256", sha)]
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
        gz.write(body)
    members.append((name + ".img.gz", buf.getvalue()))
blobs = [("manifest", "".join(k + "=" + str(v) + "\n" for k, v in fields).encode())]
blobs += members
with tarfile.open(out, "w", format=tarfile.USTAR_FORMAT) as archive:
    for name, blob in blobs:
        info = tarfile.TarInfo(name)
        info.size, info.mtime = len(blob), 0
        archive.addfile(info, io.BytesIO(blob))
PY

  reset() {
    rm -f /tmp/flip.log /tmp/splash.log /tmp/reboot.log /mnt/SDCARD/*.bosupd
    rm -rf /data/update
    dd if=/dev/zero of=/dev/mmcblk1 bs=1M count=6 status=none
  }
  # payload TARGET VERSION BUILD [flaw]
  payload() { python3 /mkpayload.py "/mnt/SDCARD/baseos-my355-$2.bosupd" "$@"; }
  no_flip() { [ ! -e /tmp/flip.log ] || { echo "flipped: $1" >&2; exit 1; }; }
  refused() { grep -q "UPDATE FAILED" /tmp/splash.log; }

  # No payload on either card: nothing happens at all.
  reset
  sh /test/baseos-update apply
  no_flip "with no payload"
  [ ! -e /tmp/splash.log ]

  # Built for another device, or for a card with different slots.
  for flaw in target badslots; do
    reset
    if [ "$flaw" = target ]; then payload rg40xxv 0.4.0 def
    else payload my355 0.4.0 def badslots; fi
    if sh /test/baseos-update apply; then echo "$flaw was accepted" >&2; exit 1; fi
    no_flip "a $flaw mismatch"
    refused
  done

  # A payload whose image does not hash to its manifest is written but never
  # committed: the GPT is what makes a slot live, and it is untouched.
  reset
  payload my355 0.4.0 def corrupt
  if sh /test/baseos-update apply; then echo "corrupt payload accepted" >&2; exit 1; fi
  no_flip "a failed verify"
  refused
  [ ! -f /data/update/state ]

  # The good case: all three halves written, all three flipped, once.
  reset
  payload my355 0.4.0 def
  sh /test/baseos-update apply
  [ "$(cat /tmp/flip.log)" = "uboot boot rootfs" ]
  for pair in uboot:1 boot:3 rootfs:5; do
    dd if=/dev/mmcblk1 bs=1M skip="${pair#*:}" count=1 of=/tmp/got.bin status=none
    cmp /tmp/got.bin "/tmp/expect-${pair%:*}.bin"
  done
  # The halves it is running from are untouched, which is what makes the write
  # reversible right up to the flip.
  dd if=/dev/zero of=/tmp/zero.bin bs=1M count=1 status=none
  for at in 0 2 4; do
    dd if=/dev/mmcblk1 bs=1M skip="$at" count=1 of=/tmp/got.bin status=none
    cmp /tmp/got.bin /tmp/zero.bin
  done
  grep -q " 0.4.0 def$" /data/update/history
  grep -qx "attempts=0" /data/update/state
  [ -e /tmp/reboot.log ]

  # Same payload still on the card next boot: recorded in history, never redone.
  rm -f /tmp/flip.log
  sh /test/baseos-update apply
  no_flip "an already-applied payload"

  # Nor is one older than the running version, which would ping-pong.
  reset
  payload my355 0.2.0 old
  sh /test/baseos-update apply
  no_flip "an older payload"

  # The trial: two quiet boots, then the third restores the previous slots.
  reset
  mkdir -p /data/update
  printf "trial=0.4.0\nattempts=0\nsha=x\n" > /data/update/state
  sh /test/baseos-update boot-check
  grep -qx "attempts=1" /data/update/state
  sh /test/baseos-update boot-check
  grep -qx "attempts=2" /data/update/state
  sh /test/baseos-update boot-check
  [ "$(cat /tmp/flip.log)" = "uboot boot rootfs" ]
  [ ! -f /data/update/state ]
  grep -q "RESTORING SYSTEM" /tmp/splash.log

  # A session starting ends the trial instead.
  reset
  mkdir -p /data/update
  printf "trial=0.4.0\nattempts=1\nsha=x\n" > /data/update/state
  sh /test/baseos-update confirm
  [ ! -f /data/update/state ]

  echo "  PASS commits only what verifies, never twice, and rolls back"
'
