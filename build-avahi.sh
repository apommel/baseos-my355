#!/bin/sh
# Build a static avahi-daemon (musl, no D-Bus) for <hostname>.local, into
# work/my355/avahi/. Stock has no mDNS responder to harvest. Skipped when this
# script has not changed since the last good build.
# The recipe is upstream BaseOS's (build-tools.sh).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/common.sh
. "$HERE/tools/common.sh"
OUT="$HERE/work/my355/avahi"
mkdir -p "$OUT"

STAMP="$(baseos_sha256 "$0")"
if [ -x "$OUT/avahi-daemon" ] && [ "$(cat "$OUT/stamp" 2>/dev/null || true)" = "$STAMP" ]; then
  echo "avahi-daemon: up to date"
  exit 0
fi
rm -f "$OUT/stamp"

echo "== building avahi-daemon =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_AARCH64" \
  -v "$OUT":/out alpine:3.20 sh -euc '
  apk add -q build-base pkgconf \
    expat-dev expat-static libevent-dev libevent-static linux-headers

  # Only the library: the legacy libdaemon tests need glibc headers.
  LIBDAEMON_VERSION=0.14
  LIBDAEMON_SHA256=fd23eb5f6f986dcc7e708307355ba3289abe03cc381fc47a80bca4a50aa6b834
  cd /tmp
  wget -q "https://0pointer.de/lennart/projects/libdaemon/libdaemon-$LIBDAEMON_VERSION.tar.gz"
  echo "$LIBDAEMON_SHA256  libdaemon-$LIBDAEMON_VERSION.tar.gz" | sha256sum -c - >/dev/null
  tar xf "libdaemon-$LIBDAEMON_VERSION.tar.gz"
  cd "libdaemon-$LIBDAEMON_VERSION"
  # The 2008-era config.guess cannot parse a modern kernel release string.
  ./configure --build=aarch64-unknown-linux-gnu \
    --disable-shared --enable-static --prefix=/usr >/dev/null
  make -C libdaemon -j"$(nproc)" >/dev/null
  make -C libdaemon install >/dev/null

  AVAHI_VERSION=0.8
  AVAHI_SHA256=060309d7a333d38d951bc27598c677af1796934dbd98e1024e7ad8de798fedda
  cd /tmp
  wget -q "https://github.com/lathiat/avahi/releases/download/v$AVAHI_VERSION/avahi-$AVAHI_VERSION.tar.gz"
  echo "$AVAHI_SHA256  avahi-$AVAHI_VERSION.tar.gz" | sha256sum -c - >/dev/null
  tar xf "avahi-$AVAHI_VERSION.tar.gz"
  cd "avahi-$AVAHI_VERSION"
  ./configure --build=aarch64-unknown-linux-gnu \
    --prefix=/usr --sysconfdir=/etc --localstatedir=/var \
    --disable-dbus --disable-glib --disable-gobject --disable-gtk3 \
    --disable-qt4 --disable-qt5 \
    --disable-python --disable-python-dbus --disable-pygobject \
    --disable-gdbm \
    --disable-manpages --disable-doxygen-doc --disable-xmltoman \
    --disable-compat-howl --disable-compat-libdns_sd \
    --disable-shared --enable-static \
    --with-distro=none \
    LIBDAEMON_CFLAGS=-I/usr/include \
    LIBDAEMON_LIBS=-ldaemon >/dev/null
  make -j"$(nproc)" >/dev/null 2>&1
  # libtool eats a bare -static on program links; relink the daemon fully static.
  touch avahi-daemon/main.c
  make -C avahi-daemon LDFLAGS=-all-static avahi-daemon >/dev/null 2>&1
  strip avahi-daemon/avahi-daemon
  cp avahi-daemon/avahi-daemon /out/avahi-daemon
  chmod 755 /out/avahi-daemon
  readelf -l /out/avahi-daemon | grep -q INTERP && { echo "avahi-daemon is not static" >&2; exit 1; }
  echo "  avahi-daemon $AVAHI_VERSION: $(stat -c %s /out/avahi-daemon) bytes, static"
'
# Only after a good build, so a failed one leaves the stamp stale.
printf '%s\n' "$STAMP" > "$OUT/stamp"
