#!/bin/sh
# Link U-Boot's own compiled decompressors (gzip, zstd, lz4, lzma, lzo, bzip2)
# into static programs to time them on the device, in variants
# (docs/uboot.md, "Kernel compression, revisited"):
#   S as U-Boot builds them: -Os, -mstrict-align except zstd/zlib (patch 0003)
#   U every decoder without -mstrict-align
#   M U, and lz4's fixed-size copies as __builtin_memcpy, not lib/string.c's
#   O M at -O2
# After ./build-uboot.sh, from the repository root, on an arm64 host:
#   docker run --rm -v "$PWD/work/uboot/build/u-boot-2026.01":/u:ro \
#     -v "$PWD/tools/uboot/decomp-bench":/z:ro -v "$PWD/work/uboot/decomp-bench":/out \
#     debian:bookworm-slim sh /z/build.sh
# then on the device, with the clock pinned: bench-M lz4 kernel.lz4 5 Image
set -eu
apt-get -qq update >/dev/null
apt-get -qq install -y --no-install-recommends gcc libc6-dev binutils >/dev/null 2>&1

cd /u
FLAGS=$(head -1 lib/.string.o.cmd | sed 's/^cmd_[^=]*:= //' | tr ' ' '\n' |
  grep -v -e '^-Wp,' -e '^-DKBUILD_' -e '^-o$' -e '^-c$' -e '\.o$' -e '\.c$' -e 'gcc$' |
  grep -v '^$' | tr '\n' ' ')
NOSTRICT=$(echo "$FLAGS" | sed 's/-mstrict-align//')
O2=$(echo "$NOSTRICT" | sed 's/-Os/-O2/')
ZSRC="lib/zstd/zstd_decompress_module.c lib/zstd/decompress/huf_decompress.c
  lib/zstd/decompress/zstd_ddict.c lib/zstd/decompress/zstd_decompress.c
  lib/zstd/decompress/zstd_decompress_block.c lib/zstd/zstd.c
  lib/zstd/zstd_common_module.c lib/zstd/common/debug.c
  lib/zstd/common/entropy_common.c lib/zstd/common/error_private.c
  lib/zstd/common/fse_decompress.c lib/zstd/common/zstd_common.c lib/xxhash.c"
OSRC="lib/lzma/LzmaDec.c lib/lzma/LzmaTools.c lib/lzo/lzo1x_decompress.c
  lib/bzip2/bzlib.c lib/bzip2/bzlib_crctable.c lib/bzip2/bzlib_decompress.c
  lib/bzip2/bzlib_huffman.c lib/bzip2/bzlib_randtable.c"

# lz4_wrapper.c #includes lz4.c; M patches a copy of the pair.
LZ4M=/tmp/lz4m
mkdir -p $LZ4M
cp lib/lz4_wrapper.c lib/lz4.c $LZ4M/
sed -i 's/\bmemcpy(/__builtin_memcpy(/g' $LZ4M/lz4.c

cc_set() {	# out-dir flags sources...
  d=$1 f=$2; shift 2; mkdir -p "$d"
  for s in "$@"; do
    # shellcheck disable=SC2086
    gcc $f -c "$s" -o "$d/$(echo "$s" | tr / _).o"
  done
}

O=/out/obj; rm -rf "$O"
cc_set $O/base "$FLAGS" lib/gunzip.c lib/string.c lib/ctype.c lib/crc32.c
# shellcheck disable=SC2086
{
cc_set $O/S "$FLAGS" $OSRC lib/lz4_wrapper.c
cc_set $O/S "$NOSTRICT" lib/zlib/zlib.c $ZSRC
cc_set $O/U "$NOSTRICT" lib/zlib/zlib.c $ZSRC $OSRC lib/lz4_wrapper.c
cc_set $O/M "$NOSTRICT" lib/zlib/zlib.c $ZSRC $OSRC $LZ4M/lz4_wrapper.c
cc_set $O/O "$O2" lib/zlib/zlib.c $ZSRC $OSRC $LZ4M/lz4_wrapper.c
}

# U-Boot's own string/ctype routines, renamed so glibc's never stand in.
nm --defined-only $O/base/lib_string.c.o $O/base/lib_ctype.c.o | awk '$2 ~ /[TDRB]/ {print $3, "ub_" $3}' | sort -u > /out/rename.map
for o in $(find $O -name '*.o'); do objcopy --redefine-syms=/out/rename.map "$o"; done

for v in S U M O; do
  gcc -O2 -static -Wl,--gc-sections /z/bench.c $O/base/*.o $O/$v/*.o -o /out/bench-$v
done
ls -l /out/bench-*
