#!/bin/sh
# Build the my355 (Miyoo Flip) rootfs tarball.
#
# Four sources, assembled in this order so each can override the last:
#   1. static BusyBox (Alpine busybox-static) — /bin/busybox plus applet links
#   2. the stock harvest (work/my355/prepared/stock-harvest.tar) — glibc, Mali,
#      SDL2, adbd, wpa_supplicant; a verified closure, see prepare-stock.sh
#   3. the merged-/usr skeleton the harvest assumes
#   4. overlay/ — init, inittab, rcS, the frontend session
#
# fbsplash is built from the shared src/fbsplash.c: this device has no console,
# so a status message on the panel is the only way to say "insert a card" or
# "installing frontend". It reads panel geometry from the framebuffer and
# rotation from /etc/baseos-release. src/gptgrow.c is built the same way.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/tools/docker-platform.sh"
WORK="$HERE/work/my355"
PREPARED="$WORK/prepared"
mkdir -p "$WORK"

BASEOS_VERSION="$(tr -d ' \n' < "$HERE/VERSION")"
[ -n "$BASEOS_VERSION" ] || { echo "VERSION is empty" >&2; exit 1; }
BASEOS_BUILD="$(git -C "$HERE" describe --always --dirty 2>/dev/null || echo unknown)"


for artifact in source.json stock-harvest.tar; do
  [ -f "$PREPARED/$artifact" ] || {
    echo "missing $PREPARED/$artifact" >&2
    echo "run ./fetch-prepared.sh, or ./prepare-stock.sh from a NAND dump" >&2
    exit 1
  }
done
python3 "$HERE/tools/source_manifest.py" verify "$PREPARED/source.json" "$PREPARED" --quiet

docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$WORK":/work -v "$HERE/overlay":/overlay:ro \
  -v "$HERE/src":/src:ro -v "$HERE/assets":/assets:ro \
  -e BASEOS_VERSION="$BASEOS_VERSION" -e BASEOS_BUILD="$BASEOS_BUILD" \
  alpine:3.20 sh -euc '
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

  # Stock uses the lowercase path, NextUI the uppercase one.
  ln -sfn /mnt/SDCARD "$R"/mnt/sdcard

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
  cp /assets/card-readme.txt "$R"/usr/share/baseos/card-readme.txt

  # The GPT tools: gptgrow for first-boot expand-to-fill, gptslot for A/B
  # updates (overlay/usr/sbin/expand-storage, overlay/usr/sbin/baseos-update).
  for t in gptgrow gptslot; do
    gcc -static -O2 -o "$R"/usr/sbin/"$t" /src/"$t".c
    strip "$R"/usr/sbin/"$t"
  done

  # 3. The overlay wins over everything.
  cp -a /overlay/. "$R"/
  chmod +x "$R"/init "$R"/etc/init.d/* \
           "$R"/usr/sbin/nextui-session "$R"/usr/sbin/usb-gadget-adb \
           "$R"/usr/sbin/expand-storage "$R"/usr/sbin/mount-frontend \
           "$R"/usr/sbin/baseos-update \
           "$R"/usr/bin/baseos-splash "$R"/usr/share/udhcpc/default.script

  # All three from VERSION so they cannot drift. NextUI reads
  # /usr/miyoo/version for its About screen.
  {
    printf "BASEOS_VERSION=%s\n" "$BASEOS_VERSION"
    printf "BASEOS_BUILD=%s\n" "$BASEOS_BUILD"
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
  # which nextui-session bind-mounts onto the frontend card.
  ln -sf /userdata/localtime "$R"/etc/localtime

  # resolv.conf is written by the udhcpc event script into /run.
  ln -sf /run/resolv.conf "$R"/etc/resolv.conf

  # rcS restores machine-id from /data into tmpfs; the baked symlink keeps the
  # root filesystem off the boot path.
  ln -sf /run/machine-id "$R"/etc/machine-id

  tar -cf /work/rootfs.tar -C "$R" .
  echo "  rootfs: $(tar -tf /work/rootfs.tar | wc -l) entries, $(stat -c %s /work/rootfs.tar) bytes"
  echo "  busybox applets: $(chroot "$R" /usr/bin/busybox --list | wc -l)"
'
echo "rootfs: $WORK/rootfs.tar"
