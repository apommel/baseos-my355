#!/bin/sh
# What the frontend on a running Flip needs from the rootfs (tools/abi_scan.py).
#
# Pulls over adb every ELF and script in the card's my355 trees, and the maps
# of every running process, into work/abi; then reports against rootfs.tar,
# with the stock harvest behind it for what the build does not provide.
#
# Usage: tools/frontend-abi.sh [--no-pull]
set -eu

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/work/abi"
CARD="$OUT/card"
TREES=".system/my355 .tmp_update Emus/my355 Tools/my355"

if [ "${1:-}" != --no-pull ]; then
  mkdir -p "$CARD"
  # Size and path of each ELF or script; adb shell ends lines with \r.
  # shellcheck disable=SC2016
  adb shell "cd /mnt/SDCARD && find $TREES -type f 2>/dev/null"' | while read -r f; do
      m=$(head -c4 "$f" | tail -c3); h=$(head -c2 "$f")
      [ "$m" = ELF ] || [ "$h" = "#!" ] && echo "$(stat -c %s "$f") $f"; done' |
    tr -d '\r' > "$OUT/files.txt"
  while read -r size f; do
    [ -f "$CARD/$f" ] && [ "$(wc -c < "$CARD/$f" | tr -d ' ')" = "$size" ] && continue
    mkdir -p "$CARD/$(dirname "$f")"
    adb pull "/mnt/SDCARD/$f" "$CARD/$f" </dev/null >/dev/null
  done < "$OUT/files.txt"
  echo "pulled $(wc -l < "$OUT/files.txt" | tr -d ' ') files into $CARD"
  # shellcheck disable=SC2016
  adb shell 'for p in /proc/[0-9]*; do c=$(cat $p/comm 2>/dev/null)
      sed "s|^|$c |" $p/maps 2>/dev/null; done' |
    tr -d '\r' | awk '{print $1, $NF}' | sort -u > "$OUT/maps.txt"
fi

zstd -dc "$HERE"/work/dl/stock-firmware/*.tar.zst | tar -xOf - prepared/stock-harvest.tar > "$OUT/stock-harvest.tar"
python3 "$HERE/tools/abi_scan.py" "$CARD" \
  "$HERE/work/images/rootfs.tar" "$OUT/stock-harvest.tar" \
  --maps "$OUT/maps.txt" --json "$OUT/abi.json" | tee "$OUT/abi.txt"
