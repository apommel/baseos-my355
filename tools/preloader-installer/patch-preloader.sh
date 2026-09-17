#!/bin/sh
# Patch a my355 preloader image in place, on the device, using only BusyBox.
# The same edit as tools/mkpreloader.py; rationale in docs/boot-chain.md.
#
# usage: patch-preloader.sh IN.img OUT.img
set -e

IN="$1"; OUT="$2"
AWK="${AWK_SCRIPT:-$(dirname "$0")/fdtpatch.awk}"
SIZE=2097152
FIRST=131072                    # the two IDB copies, at 0x20000 and 0x80000
COPIES="$FIRST 524288"

die() { echo "refused: $*" >&2; exit 1; }

u16le() { # file offset
    h=$(xxd -s "$2" -l 2 -p "$1")
    echo $(( 0x$(echo "$h" | cut -c3-4)$(echo "$h" | cut -c1-2) ))
}
sha_range() { # file byteoffset length
    dd if="$1" bs=512 skip=$(( $2 / 512 )) count=$(( $3 / 512 )) 2>/dev/null | sha256sum | cut -c1-64
}
stored_hash() { # file entryoffset
    xxd -s $(( $2 + 0x18 )) -l 32 -p "$1" | tr -d '\n'
}

[ -f "$IN" ] || die "no such file: $IN"
[ "$(wc -c < "$IN")" -eq "$SIZE" ] || die "input is not $SIZE bytes"

# --- parse both IDB copies, and check the image is intact before touching it ---
for base in $COPIES; do
    [ "$(xxd -s "$base" -l 4 -p "$IN")" = "524b4e53" ] || die "no RKNS magic at $base"
    for i in 0 1; do
        e=$(( base + 0x78 + i * 0x58 ))
        off=$(u16le "$IN" $e); cnt=$(u16le "$IN" $(( e + 2 )))
        [ "$cnt" -gt 0 ] || die "empty IDB entry $i at $base"
        want=$(stored_hash "$IN" $e)
        got=$(sha_range "$IN" $(( base + off * 512 )) $(( cnt * 512 )))
        [ "$want" = "$got" ] || die "IDB entry $i at $base fails its own SHA-256"
        # Both copies are identical, so the first one's geometry drives the
        # patch: entry 0 is the DDR blob, entry 1 the SPL. Only the SPL is
        # touched.
        case "$base:$i" in
            "$FIRST:0") DDR_OFF=$off; DDR_CNT=$cnt ;;
            "$FIRST:1") SPL_OFF=$off; SPL_CNT=$cnt ;;
        esac
    done
done

SPL=$(( FIRST + SPL_OFF * 512 ))
SPL_LEN=$(( SPL_CNT * 512 ))

# --- locate the device tree: it sits at the end of the SPL payload ---
DTB=""
w=32768; s=$(( SPL + SPL_LEN - w ))
while [ "$s" -ge "$SPL" ]; do
    hex=$(dd if="$IN" bs=512 skip=$(( s / 512 )) count=$(( w / 512 )) 2>/dev/null | xxd -p | tr -d '\n')
    p=$(echo "$hex" | awk '{ print index($0, "d00dfeed") }')
    if [ "$p" -gt 0 ] && [ $(( (p - 1) % 2 )) -eq 0 ]; then
        DTB=$(( s + (p - 1) / 2 )); break
    fi
    s=$(( s - w ))
done
[ -n "$DTB" ] || die "no device tree found in the SPL payload"
TOTAL=$(( 0x$(xxd -s $(( DTB + 4 )) -l 4 -p "$IN") ))
[ "$TOTAL" -gt 0 ] && [ $(( DTB + TOTAL )) -le $(( SPL + SPL_LEN )) ] || die "device tree overruns its payload"

# --- patch ---
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
dd if="$IN" bs=1 skip="$DTB" count="$TOTAL" of="$T/old.dtb" 2>/dev/null
xxd -p "$T/old.dtb" | tr -d '\n' | awk -f "$AWK" | xxd -r -p > "$T/new.dtb"
NEW=$(wc -c < "$T/new.dtb")
GROWTH=$(( NEW - TOTAL ))
SLACK=$(( SPL + SPL_LEN - DTB - TOTAL ))
[ "$GROWTH" -gt 0 ] || die "patched tree did not grow"
[ "$GROWTH" -le "$SLACK" ] || die "patched tree needs $GROWTH bytes, only $SLACK free"
TAIL=$(dd if="$IN" bs=1 skip=$(( DTB + TOTAL )) count="$SLACK" 2>/dev/null | tr -d '\000' | wc -c)
[ "$TAIL" -eq 0 ] || die "$TAIL non-zero bytes after the device tree"

cp "$IN" "$OUT"
for base in $COPIES; do
    at=$(( DTB + base - FIRST ))
    dd if="$T/new.dtb" of="$OUT" bs=1 seek="$at" conv=notrunc 2>/dev/null
done

# --- reseal: the SPL entry's SHA-256 in both copies ---
H=$(sha_range "$OUT" "$SPL" "$SPL_LEN")
echo "$H" | xxd -r -p > "$T/h.bin"
for base in $COPIES; do
    dd if="$T/h.bin" of="$OUT" bs=1 seek=$(( base + 0x78 + 0x58 + 0x18 )) conv=notrunc 2>/dev/null
done

# --- verify the result on its own terms ---
[ "$(wc -c < "$OUT")" -eq "$SIZE" ] || die "output changed size"
for base in $COPIES; do
    for i in 0 1; do
        e=$(( base + 0x78 + i * 0x58 ))
        off=$(u16le "$OUT" $e); cnt=$(u16le "$OUT" $(( e + 2 )))
        want=$(stored_hash "$OUT" $e)
        got=$(sha_range "$OUT" $(( base + off * 512 )) $(( cnt * 512 )))
        [ "$want" = "$got" ] || die "output IDB entry $i at $base fails its SHA-256"
    done
done
A=$(dd if="$IN"  bs=512 skip=$(( FIRST / 512 + DDR_OFF )) count="$DDR_CNT" 2>/dev/null | sha256sum)
B=$(dd if="$OUT" bs=512 skip=$(( FIRST / 512 + DDR_OFF )) count="$DDR_CNT" 2>/dev/null | sha256sum)
[ "$A" = "$B" ] || die "the DDR blob changed"
A=$(dd if="$IN"  bs=1 skip="$SPL" count=$(( DTB - SPL )) 2>/dev/null | sha256sum)
B=$(dd if="$OUT" bs=1 skip="$SPL" count=$(( DTB - SPL )) 2>/dev/null | sha256sum)
[ "$A" = "$B" ] || die "the SPL code changed"

echo "device tree $TOTAL -> $NEW (+$GROWTH), slack $SLACK, both IDB copies resealed"
echo "ok: $OUT"
