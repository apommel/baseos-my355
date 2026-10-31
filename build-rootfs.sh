#!/bin/sh
# Build the my355 (Miyoo Flip) rootfs tarball.
#
# Four sources, assembled in this order so each can override the last:
#   1. ./build-userland.sh's Buildroot target — merged /usr, glibc, SDL3 under
#      sdl2-compat, libmali, BlueZ, wpa_supplicant, curl, adbd, ...
#      (docs/rootfs-interface.md)
#   2. static BusyBox (Alpine busybox-static) — /bin/busybox plus applet links,
#      where Buildroot left a name free
#   3. ./build-kernel.sh's modules, ./build-gpu.sh's Mesa, and the two files
#      still taken from stock: the Bluetooth firmware
#   4. overlay/ — init, rcS, the frontend session, and the stand-ins for the
#      stock files mainline drivers replace; with MY355_DIAG=1 overlay-diag/ on
#      top: boot-timing probes, not for release
#
# Every library a program in the result links must be in it, or the build fails.
#
# fbsplash is built from src/fbsplash.c: this device has no console, so a status
# message on the panel is the only way to say "insert a card" or "installing
# frontend". It reads panel geometry from the framebuffer and rotation from
# /etc/baseos-release. src/gptgrow.c is built the same way.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"
WORK="$HERE/work/my355"
PREPARED="$WORK/prepared"
mkdir -p "$WORK"

BASEOS_VERSION="$(baseos_version)"
BASEOS_BUILD="$(git -C "$HERE" describe --always --dirty 2>/dev/null || echo unknown)"
# Two builds of the same uncommitted tree would otherwise share an id, and a card
# skips a same-version payload whose id matches its own. build-update.sh reads it.
case "$BASEOS_BUILD" in *-dirty) BASEOS_BUILD="$BASEOS_BUILD-$(date -u +%Y%m%d%H%M%S)" ;; esac
printf '%s\n' "$BASEOS_BUILD" > "$WORK/build-id"

baseos_require_prepared "$PREPARED"
baseos_require_aarch64

DIAG="${MY355_DIAG:-0}"
case "$DIAG" in 0|1) ;; *) echo "MY355_DIAG must be 0 or 1" >&2; exit 1 ;; esac
[ "$DIAG" = 1 ] && echo "== MY355_DIAG=1: adding overlay-diag/ (not for release) =="

[ -f "$WORK/userland.tar" ] || {
  echo "missing $WORK/userland.tar (run ./build-userland.sh)" >&2; exit 1; }
[ -f "$WORK/kernel/modules.tar" ] || {
  echo "missing $WORK/kernel/modules.tar (run ./build-kernel.sh)" >&2; exit 1; }
[ -f "$WORK/gpu/mesa.tar" ] || {
  echo "missing $WORK/gpu/mesa.tar (run ./build-gpu.sh)" >&2; exit 1; }

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$WORK":/work -v "$HERE/overlay":/overlay:ro \
  -v "$HERE/overlay-diag":/overlay-diag:ro -e DIAG="$DIAG" \
  -v "$HERE/src":/src:ro -v "$HERE/assets":/assets:ro \
  -e BASEOS_VERSION="$BASEOS_VERSION" -e BASEOS_BUILD="$BASEOS_BUILD" \
  alpine:3.20 sh -euc '
  apk add -q busybox-static
  R=/tmp/rootfs; rm -rf "$R"; mkdir -p "$R"

  # 1. Buildroot: merged /usr (bin, sbin, lib and lib64 link into it), as stock.
  tar -xf /work/userland.tar -C "$R"
  # Replaced below by links or generated files; /root becomes a link.
  rm -rf "$R"/root "$R"/etc/os-release "$R"/etc/localtime "$R"/etc/timezone \
         "$R"/etc/resolv.conf "$R"/etc/hostname "$R"/etc/hosts "$R"/etc/shadow
  # Frontends export LD_LIBRARY_PATH with their own libcrypto, libzstd, ...
  # first; DT_RPATH, unlike DT_RUNPATH, is searched before it.
  apk add -q pax-utils patchelf
  scanelf -RBF "%n;%F" "$R"/usr 2>/dev/null | while IFS=";" read -r needed f; do
    if [ -n "$needed" ]; then patchelf --force-rpath --set-rpath /usr/lib "$f"; fi
  done

  mkdir -p "$R"/proc "$R"/sys "$R"/dev "$R"/tmp "$R"/run "$R"/var \
           "$R"/data "$R"/mnt/SDCARD "$R"/etc \
           "$R"/userdata  # the frontend bind-mounts its card copy here, as on stock

  # Stock uses the lowercase path, NextUI the uppercase one.
  ln -sfn /mnt/SDCARD "$R"/mnt/sdcard

  # 2. BusyBox and its applet links (mount, sh, init, getty, ... — rcS calls
  #    them by path, so the links must exist). --install leaves a name
  #    Buildroot already filled, so its programs win.
  cp /bin/busybox.static "$R"/usr/bin/busybox
  chroot "$R" /usr/bin/busybox --install -s
  # -L, not -e: the links --install writes are absolute, so they resolve only
  # on the device.
  [ -L "$R"/sbin/init ] || { echo "busybox --install left no /sbin/init" >&2; exit 1; }

  # 3. The Bluetooth firmware, the only stock files left: no source exists.
  tar -xf /work/prepared/stock-harvest.tar -C "$R" \
    usr/lib/firmware/rtl8733bu_fw usr/lib/firmware/rtl8733bu_config
  # lib/modules/<release>, depmod already run.
  tar -xf /work/kernel/modules.tar -C "$R"/usr
  # bt_init.sh insmods this path: the stand-in that loads mainline btusb.
  cp "$R"/usr/lib/modules/*/kernel/drivers/bluetooth/rtk_btusb.ko "$R"/usr/lib/modules/
  # The second GPU stack baseos-gpu picks from, beside libmali: Mesa in usr/lib/mesa.
  tar -xf /work/gpu/mesa.tar -C "$R"
  # modetest moves aside for the wrapper in overlay/ that maps its object ids.
  mv "$R"/usr/bin/modetest "$R"/usr/libexec/modetest

  # fbsplash: the panel is the only output device this hardware has.
  apk add -q build-base linux-headers pkgconf \
    freetype-dev freetype-static zlib-static libpng-static bzip2-static brotli-static
  gcc -static -O2 $(pkg-config --cflags freetype2) -o "$R"/usr/bin/fbsplash \
    /src/fbsplash.c $(pkg-config --static --libs freetype2)
  strip "$R"/usr/bin/fbsplash
  mkdir -p "$R"/usr/share/baseos
  cp /assets/boot.ttf "$R"/usr/share/baseos/boot.ttf
  cp /assets/card-readme.txt "$R"/usr/share/baseos/card-readme.txt
  cp /assets/baseos.conf "$R"/usr/share/baseos/baseos.conf

  # The GPT tools: gptgrow for first-boot expand-to-fill, gptslot for A/B
  # updates (overlay/usr/sbin/expand-storage, overlay/usr/sbin/baseos-update).
  # rebootmode: a reboot argument (charge) for rcK, which busybox cannot pass.
  # pwrkeyd: a clean poweroff on a 2 s hold of the power key, without a frontend.
  # fatdirty: FAT32 or exFAT, and whether a card needs fsck before it is mounted.
  # wifibtd: Bluetooth on/off, for when to power the WiFi/BT chip (wifibt-power).
  for t in gptgrow gptslot rebootmode pwrkeyd fatdirty wifibtd; do
    gcc -static -O2 -o "$R"/usr/sbin/"$t" /src/"$t".c
    strip "$R"/usr/sbin/"$t"
  done

  # 4. The overlay wins over everything. cp -a carries the modes across, and
  #    every script in overlay/ is committed executable.
  # overlay/usr/sbin/poweroff replaces an applet link; cp would write through
  # it into busybox itself.
  rm -f "$R"/usr/sbin/poweroff
  cp -a /overlay/. "$R"/
  if [ "$DIAG" = 1 ]; then cp -a /overlay-diag/. "$R"/; fi

  # cfg80211 reads it at load, or every channel stays at the world limits.
  apk add -q wireless-regdb
  cp /lib/firmware/regulatory.db /lib/firmware/regulatory.db.p7s "$R"/usr/lib/firmware/

  # All three from VERSION so they cannot drift. NextUI reads
  # /usr/miyoo/version for its About screen.
  {
    printf "BASEOS_VERSION=%s\n" "$BASEOS_VERSION"
    printf "BASEOS_BUILD=%s\n" "$BASEOS_BUILD"
    if [ "$DIAG" = 1 ]; then printf "BASEOS_DIAG=1\n"; fi
  } >> "$R"/etc/baseos-release
  {
    printf "NAME=\"BaseOS\"\nID=baseos\n"
    printf "VERSION_ID=%s\n" "$BASEOS_VERSION"
    printf "PRETTY_NAME=\"BaseOS %s (my355)\"\n" "$BASEOS_VERSION"
    printf "HOME_URL=\"https://github.com/apommel/baseos-my355\"\n"
  } > "$R"/etc/os-release
  mkdir -p "$R"/usr/miyoo
  printf "BaseOS %s\n" "$BASEOS_VERSION" > "$R"/usr/miyoo/version

  # Same target as stock: NextUI copies the chosen zone into /userdata/localtime,
  # which the frontend bind-mounts onto its card.
  ln -sf /userdata/localtime "$R"/etc/localtime

  # The root is mounted read-only, so the home of root (shell history, SSH
  # keys) lives on /data; /etc/init.d/dev creates it.
  ln -sfn /data/root "$R"/root

  # resolv.conf is written by the udhcpc event script into /run.
  ln -sf /run/resolv.conf "$R"/etc/resolv.conf

  # rcS restores machine-id from /data into tmpfs; the baked symlink keeps the
  # root filesystem off the boot path.
  ln -sf /run/machine-id "$R"/etc/machine-id

  # baseos-config writes these into /run from baseos.conf on the card, starting
  # from this shadow.
  mv "$R"/etc/shadow "$R"/usr/share/baseos/shadow
  chmod 600 "$R"/usr/share/baseos/shadow
  for f in shadow hostname hosts; do ln -sf /run/"$f" "$R"/etc/"$f"; done

  # Every DT_NEEDED resolves in /usr/lib or the run path of whoever needs it.
  scanelf -RBqF "%F;%n;%r" "$R"/usr 2>/dev/null | while IFS=";" read -r f needed rpath; do
    for n in $(echo "$needed" | tr , " "); do
      found=0
      for d in /usr/lib $(echo "$rpath" | tr : " "); do
        case "$d" in "\$ORIGIN"*) d="${f#"$R"}"; d="${d%/*}" ;; esac
        [ -e "$R$d/$n" ] && { found=1; break; }
      done
      [ "$found" = 1 ] || echo "${f#"$R"} needs $n"
    done
  done > /tmp/unresolved
  [ ! -s /tmp/unresolved ] || { echo "unresolved libraries:" >&2; cat /tmp/unresolved >&2; exit 1; }

  tar -cf /work/rootfs.tar -C "$R" .
  echo "  rootfs: $(tar -tf /work/rootfs.tar | wc -l) entries, $(stat -c %s /work/rootfs.tar) bytes"
  echo "  busybox applets: $(chroot "$R" /usr/bin/busybox --list | wc -l)"
'
echo "rootfs: $WORK/rootfs.tar"
