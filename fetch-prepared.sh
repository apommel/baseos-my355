#!/bin/sh
# Restore the prepared build inputs without a NAND dump of your own.
# Usage: ./fetch-prepared.sh [--from BUNDLE] [--force]
#
# Fetches the three things prepare-stock.sh derives from internal SPI NAND —
# uboot.img, boot.img, stock-harvest.tar — and installs the source.json that
# describes them from git.
#
# A cache restore, not a second build path. The bundle SHA-256
# (manifest/prepared/bundle.sha256) covers the download; each artifact's own
# hash in source.json covers the contents, and is the check every build runs.
#
# It does not give you a preloader: tools/mkpreloader.py patches your unit's own
# mtd5, and you need a NAND backup to recover from a bad write. Take one either
# way — docs/03-nand-backup-and-recovery.md.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

PREPARED="$HERE/manifest/prepared"
WORK="$HERE/work/my355/prepared"
CACHE_DIR="$HERE/work/prepared"
BUNDLE=""
FORCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from) BUNDLE="${2:?--from needs a path}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

for f in source.json bundle.sha256 bundle.url; do
  [ -f "$PREPARED/$f" ] || {
    echo "missing $PREPARED/$f — no bundle published for this checkout" >&2
    echo "prepare from a NAND dump instead: ./prepare-stock.sh" >&2
    exit 1
  }
done

WANT_SHA="$(cut -d' ' -f1 < "$PREPARED/bundle.sha256")"
NAME="$(awk '{print $NF}' < "$PREPARED/bundle.sha256")"
URL="${BASEOS_PREPARED_URL:-$(cat "$PREPARED/bundle.url")}"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# A local source.json that differs means a prepare against a different dump.
# Overwriting it throws away the only record of what that build came from.
if [ -f "$WORK/source.json" ] && ! cmp -s "$PREPARED/source.json" "$WORK/source.json" \
   && [ "$FORCE" -eq 0 ]; then
  echo "work/my355/prepared was prepared locally from a different dump" >&2
  echo "re-run with --force to replace it with the published baseline" >&2
  exit 1
fi

mkdir -p "$WORK"
cp "$PREPARED/source.json" "$WORK/source.json"

if python3 "$HERE/tools/source_manifest.py" verify "$WORK/source.json" "$WORK" \
     >/dev/null 2>&1; then
  echo "up to date: work/my355/prepared"
  exit 0
fi

if [ -n "$BUNDLE" ]; then
  [ -f "$BUNDLE" ] || { echo "bundle not found: $BUNDLE" >&2; exit 1; }
else
  mkdir -p "$CACHE_DIR"
  BUNDLE="$CACHE_DIR/$NAME"
  if [ -f "$BUNDLE" ] && [ "$(sha256_of "$BUNDLE")" = "$WANT_SHA" ]; then
    echo "using previously downloaded $BUNDLE"
  else
    echo "downloading $URL"
    curl -fL --progress-bar -o "$BUNDLE.part" "$URL"
    mv "$BUNDLE.part" "$BUNDLE"
  fi
fi

GOT_SHA="$(sha256_of "$BUNDLE")"
if [ "$GOT_SHA" != "$WANT_SHA" ]; then
  echo "bundle SHA-256 mismatch — refusing to unpack" >&2
  echo "  expected $WANT_SHA" >&2
  echo "  got      $GOT_SHA" >&2
  exit 1
fi
echo "bundle SHA-256 OK"

BUNDLE_DIR="$(cd "$(dirname "$BUNDLE")" && pwd)"
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/work/my355":/out -v "$BUNDLE_DIR":/bundle:ro \
  -e NAME="$(basename "$BUNDLE")" \
  alpine:3.20 sh -euc '
  apk add -q tar zstd
  cd /out
  zstd -dc "/bundle/$NAME" | tar -xf - \
    prepared/uboot.img prepared/boot.img prepared/stock-harvest.tar
'

# Derived artifacts from the previous inputs are now stale; leaving them lets a
# build mix a fresh boot image with an old rootfs.
rm -f "$HERE/work/my355/rootfs.tar" "$HERE/work/my355/boot-sd.img" \
      "$HERE/work/my355/baseos-my355.img" "$HERE/work/my355/baseos-logo.bmp"

python3 "$HERE/tools/source_manifest.py" verify "$WORK/source.json" "$WORK"

echo
echo "Prepared inputs restored. Build with:"
echo "  ./build-all.sh"
