#!/bin/sh
# Link U-Boot's own compiled gunzip() and zstd_decompress() into static programs
# to time them on the device, in variants (docs/uboot.md, "zstd"):
#   A as U-Boot builds them   B without -mstrict-align   C without it or MINIFY
#   D without MINIFY only     H gzip without -mstrict-align
# After ./build-uboot.sh, from the repository root, on an arm64 host:
#   docker run --rm -v "$PWD/work/uboot/build/u-boot-2026.01":/u:ro \
#     -v "$PWD/tools/uboot/decomp-bench":/z:ro -v "$PWD/work/uboot/decomp-bench":/out \
#     debian:bookworm-slim sh /z/build.sh
# then on the device, with the clock pinned: bench-C zstd kernel.zst 3
set -eu
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends gcc libc6-dev binutils >/dev/null 2>&1

cd /u
# string.o keeps the platform flags; patches/0003 drops -mstrict-align from the
# decompressors themselves.
FLAGS=$(head -1 lib/.string.o.cmd | sed 's/^cmd_[^=]*:= //' | tr ' ' '\n' |
  grep -v -e '^-Wp,' -e '^-DKBUILD_' -e '^-o$' -e '^-c$' -e '\.o$' -e '\.c$' -e 'gcc$' |
  grep -v '^$' | tr '\n' ' ')
NOSTRICT=$(echo "$FLAGS" | sed 's/-mstrict-align//')
MINIFY="-DHUF_FORCE_DECOMPRESS_X1 -DZSTD_FORCE_DECOMPRESS_SEQUENCES_SHORT -DZSTD_NO_INLINE -DZSTD_STRIP_ERROR_STRINGS -DDYNAMIC_BMI2=0"
ZSRC="lib/zstd/zstd_decompress_module.c lib/zstd/decompress/huf_decompress.c
  lib/zstd/decompress/zstd_ddict.c lib/zstd/decompress/zstd_decompress.c
  lib/zstd/decompress/zstd_decompress_block.c lib/zstd/zstd.c
  lib/zstd/zstd_common_module.c lib/zstd/common/debug.c
  lib/zstd/common/entropy_common.c lib/zstd/common/error_private.c
  lib/zstd/common/fse_decompress.c lib/zstd/common/zstd_common.c lib/xxhash.c"

cc_set() {	# out-dir flags sources...
  d=$1 f=$2; shift 2; mkdir -p "$d"
  for s in "$@"; do
    # shellcheck disable=SC2086
    gcc $f -c "$s" -o "$d/$(echo "$s" | tr / _).o"
  done
}

O=/out/obj; rm -rf "$O"
cc_set $O/base "$FLAGS" lib/gunzip.c lib/string.c lib/ctype.c lib/crc32.c
cc_set $O/zlibA "$FLAGS" lib/zlib/zlib.c
cc_set $O/zlibH "$NOSTRICT" lib/zlib/zlib.c
# shellcheck disable=SC2086
cc_set $O/zA "$FLAGS $MINIFY" $ZSRC
cc_set $O/zB "$NOSTRICT $MINIFY" $ZSRC
cc_set $O/zC "$NOSTRICT" $ZSRC
cc_set $O/zD "$FLAGS" $ZSRC

# U-Boot's own string/ctype routines, renamed so glibc's never stand in.
nm --defined-only $O/base/lib_string.c.o $O/base/lib_ctype.c.o | awk '$2 ~ /[TDRB]/ {print $3, "ub_" $3}' | sort -u > /out/rename.map
for o in $(find $O -name '*.o'); do objcopy --redefine-syms=/out/rename.map "$o"; done

link() {	# name zlib-dir zstd-dir
  gcc -O2 -static -Wl,--gc-sections /z/bench.c $O/base/*.o $O/$2/*.o $O/$3/*.o -o /out/bench-$1
}
link A zlibA zA
link B zlibA zB
link C zlibA zC
link D zlibA zD
link H zlibH zA
ls -l /out/bench-*
