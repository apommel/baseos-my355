#!/bin/sh
# Publish the prepared-input bundle that fetch-prepared.sh restores.
# Usage: ./cache-pack.sh [YYYYMMDD]
#
# Packs uboot.img, boot.img and stock-harvest.tar into one zstd stream and
# writes the manifests that make it verifiable:
#
#   manifest/prepared/source.json     per-artifact size + SHA-256, the anchor
#   manifest/prepared/bundle.sha256   hash of the published bundle
#   manifest/prepared/bundle.url      where it lives
#
# No --long window: unlike H700's ten near-identical targets these three members
# share almost no bytes, so a large window buys nothing and would have to be
# repeated on every decompression.
#
# This redistributes vendor firmware. Read NOTICE before publishing.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tools/docker-platform.sh
. "$HERE/tools/docker-platform.sh"

STAMP="${1:-$(date +%Y%m%d)}"
case "$STAMP" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
  *) echo "usage: $0 [YYYYMMDD]" >&2; exit 2 ;;
esac

REPO_URL="https://github.com/apommel/baseos-my355"
PREPARED="$HERE/manifest/prepared"
WORK="$HERE/work/my355/prepared"
OUT_DIR="$HERE/work/prepared"
NAME="baseos-my355-prepared-$STAMP.tar.zst"
TAG="prepared-$STAMP"

for artifact in source.json uboot.img boot.img stock-harvest.tar; do
  [ -f "$WORK/$artifact" ] || {
    echo "missing $WORK/$artifact (run ./prepare-stock.sh)" >&2
    exit 1
  }
done

echo "== verifying what is about to be published =="
python3 "$HERE/tools/source_manifest.py" verify "$WORK/source.json" "$WORK"

mkdir -p "$PREPARED" "$OUT_DIR"

echo "== packing $NAME =="
docker run --rm --platform "$BASEOS_DOCKER_PLATFORM_HOST" \
  -v "$HERE/work/my355":/in:ro -v "$OUT_DIR":/out -e NAME="$NAME" \
  alpine:3.20 sh -euc '
  apk add -q tar zstd
  cd /in
  # Fixed member metadata, so the same inputs pack to the same stream and the
  # published hash only moves when the firmware does.
  tar --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - \
    prepared/uboot.img prepared/boot.img prepared/stock-harvest.tar \
    | zstd -19 -T0 -o "/out/$NAME" -f
  ls -l "/out/$NAME"
'

if command -v sha256sum >/dev/null 2>&1; then
  BUNDLE_SHA="$(sha256sum "$OUT_DIR/$NAME" | cut -d' ' -f1)"
else
  BUNDLE_SHA="$(shasum -a 256 "$OUT_DIR/$NAME" | cut -d' ' -f1)"
fi

cp "$WORK/source.json" "$PREPARED/source.json"
printf "%s  %s\n" "$BUNDLE_SHA" "$NAME" > "$PREPARED/bundle.sha256"
printf "%s/releases/download/%s/%s\n" "$REPO_URL" "$TAG" "$NAME" > "$PREPARED/bundle.url"

echo
echo "Bundle:  $OUT_DIR/$NAME"
echo "SHA-256: $BUNDLE_SHA"
echo
echo "Publish it, then commit the manifests:"
echo "  gh release create $TAG --prerelease --notes 'Prepared inputs $STAMP' \\"
echo "    $OUT_DIR/$NAME"
echo "  git add manifest/prepared && git commit -m 'chore(cache): prepared inputs $STAMP'"
