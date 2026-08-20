#!/bin/sh
# Build a rootfs tarball for my355 (Miyoo Flip).
#
# Currently only --smoke is implemented: a BusyBox-only rootfs whose sole job is
# to prove the boot chain reaches userspace on a device that can show nothing.
# This kernel has neither a UART attached nor CONFIG_FRAMEBUFFER_CONSOLE, so a
# successful boot and a dead one look identical. The smoke rootfs therefore
# signals two ways:
#
#   * it drives the `work` LED in a 1 s square wave, which stops the moment PID 1
#     dies — distinguishable by eye from the kernel's own `heartbeat` double-thump
#   * it appends stage markers to /BOOT-STAGE on the root filesystem, readable
#     afterwards from stock with the card in the LEFT slot
#
# See docs/my355/07-bringup-and-diagnostics.md.
#
# The real harvest (glibc 2.36 + /usr/miyoo libs from mtd3's squashfs) is next;
# note mtd3 is squashfs, so it needs unsquashfs rather than the H700 debugfs path.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tools/docker-platform.sh"
WORK="$HERE/work/my355"
mkdir -p "$WORK"

MODE="${1:---smoke}"
[ "$MODE" = "--smoke" ] || { echo "only --smoke is implemented so far" >&2; exit 2; }

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$WORK":/work alpine:3.20 sh -euc '
  apk add -q busybox-static
  R=/tmp/rootfs; rm -rf "$R"
  mkdir -p "$R"/bin "$R"/sbin "$R"/proc "$R"/sys "$R"/dev "$R"/mnt/data "$R"/tmp
  cp /bin/busybox.static "$R"/bin/busybox
  ln -sf busybox "$R"/bin/sh

  cat > "$R"/init <<"INIT"
#!/bin/sh
# Diagnostic init. This device has no UART and no CONFIG_FRAMEBUFFER_CONSOLE, so
# every signal has to be either a file left on disk or the LED.
BB=/bin/busybox

# Earliest possible evidence: root is mounted rw via the cmdline, so this lands
# before anything else can fail. Distinguishes "init never ran" from "init died".
echo "stage1: init entered" > /BOOT-STAGE

$BB mount -t proc proc /proc
$BB mount -t sysfs sysfs /sys
echo "stage2: proc+sys mounted" >> /BOOT-STAGE
$BB cat /proc/cmdline >> /BOOT-STAGE
$BB uname -a >> /BOOT-STAGE

# Drive the LED ourselves rather than trusting a trigger: an active blink proves
# PID 1 is still alive, and stops the instant it is not.
echo none > /sys/class/leds/work/trigger 2>/dev/null
echo "stage3: led trigger cleared" >> /BOOT-STAGE

if $BB mount -t ext4 /dev/mmcblk1p4 /mnt/data 2>/dev/null; then
  echo "stage4: data partition mounted" >> /BOOT-STAGE
  $BB cp /BOOT-STAGE /mnt/data/smoke.log 2>/dev/null
  $BB umount /mnt/data
fi
$BB sync

while :; do
  echo 0   > /sys/class/leds/work/brightness 2>/dev/null
  $BB sleep 1
  echo 255 > /sys/class/leds/work/brightness 2>/dev/null
  $BB sleep 1
done
INIT
  chmod +x "$R"/init
  # Belt and braces: the cmdline carries init=/init, but providing /sbin/init
  # means the rootfs also works under the kernel default search order.
  ln -sf ../init "$R"/sbin/init

  tar -cf /work/rootfs.tar -C "$R" .
  echo "  rootfs.tar: $(tar -tf /work/rootfs.tar | wc -l) entries, $(stat -c %s /work/rootfs.tar) bytes"
'
echo "rootfs: $WORK/rootfs.tar"
