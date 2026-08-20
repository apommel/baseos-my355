#!/bin/sh
# Build the my355 (Miyoo Flip) rootfs tarball.
#
# Four sources, assembled in this order so each can override the last:
#   1. static BusyBox (Alpine busybox-static) — /bin/busybox plus applet links
#   2. the stock harvest (work/my355/prepared/stock-harvest.tar) — glibc, Mali,
#      SDL2, adbd, wpa_supplicant; a verified closure, see prepare-stock-my355.sh
#   3. the merged-/usr skeleton the harvest assumes
#   4. overlay-my355/ — init, inittab, rcS, the frontend session
#
# fbsplash is built from the shared src/fbsplash.c: this device has no console,
# so a status message on the panel is the only way to say "insert a card" or
# "installing frontend". It reads panel geometry from the framebuffer and
# rotation from /etc/baseos-release.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tools/docker-platform.sh"
WORK="$HERE/work/my355"
PREPARED="$WORK/prepared"
mkdir -p "$WORK"


[ -f "$PREPARED/stock-harvest.tar" ] || {
  echo "missing $PREPARED/stock-harvest.tar (run ./prepare-stock-my355.sh)" >&2
  exit 1
}

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$WORK":/work -v "$HERE/overlay-my355":/overlay:ro \
  -v "$HERE/src":/src:ro -v "$HERE/assets":/assets:ro alpine:3.20 sh -euc '
  apk add -q busybox-static
  R=/tmp/rootfs; rm -rf "$R"; mkdir -p "$R"

  # Merged /usr, matching the stock rootfs the harvest came from.
  mkdir -p "$R"/usr/bin "$R"/usr/sbin "$R"/usr/lib "$R"/usr/share
  ln -sf usr/bin  "$R"/bin
  ln -sf usr/sbin "$R"/sbin
  ln -sf usr/lib  "$R"/lib
  ln -sf lib      "$R"/lib64

  mkdir -p "$R"/proc "$R"/sys "$R"/dev "$R"/tmp "$R"/run "$R"/var \
           "$R"/data "$R"/mnt/SDCARD "$R"/root "$R"/etc

  # 1. BusyBox and its applet links (mount, sh, init, getty, ... — rcS calls
  #    them by path, so the links must exist).
  cp /bin/busybox.static "$R"/usr/bin/busybox
  chroot "$R" /usr/bin/busybox --install -s 2>/dev/null || \
    for a in $(chroot "$R" /usr/bin/busybox --list); do
      ln -sf /usr/bin/busybox "$R"/usr/bin/"$a" 2>/dev/null || true
    done

  # 2. The stock harvest. Applied after BusyBox so vendor binaries win where
  #    both provide a name.
  tar -xf /work/prepared/stock-harvest.tar -C "$R"

  # fbsplash: the panel is the only output device this hardware has.
  apk add -q build-base linux-headers pkgconf \
    freetype-dev freetype-static zlib-static libpng-static bzip2-static brotli-static
  gcc -static -O2 $(pkg-config --cflags freetype2) -o "$R"/usr/bin/fbsplash \
    /src/fbsplash.c $(pkg-config --static --libs freetype2)
  strip "$R"/usr/bin/fbsplash
  mkdir -p "$R"/usr/share/baseos
  cp /assets/boot.ttf "$R"/usr/share/baseos/boot.ttf

  # 3. The overlay wins over everything.
  cp -a /overlay/. "$R"/
  chmod +x "$R"/init "$R"/etc/init.d/rcS "$R"/etc/init.d/rcK \
           "$R"/usr/sbin/nextui-session "$R"/usr/sbin/usb-gadget-adb \
           "$R"/usr/bin/baseos-splash

  # /etc/localtime is a symlink into tmpfs because the root may be read-only.
  ln -sf /run/localtime "$R"/etc/localtime

  tar -cf /work/rootfs.tar -C "$R" .
  echo "  rootfs: $(tar -tf /work/rootfs.tar | wc -l) entries, $(stat -c %s /work/rootfs.tar) bytes"
  echo "  busybox applets: $(chroot "$R" /usr/bin/busybox --list | wc -l)"
'
echo "rootfs: $WORK/rootfs.tar"
