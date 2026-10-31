#!/bin/sh
# Composes the card image and the .bosupd update from Buildroot's images
# (docs/card.md): the uboot and boot FITs, the EROFS rootfs, data and primary.
set -eu
B="$1"
TOOLS="$BR2_EXTERNAL_BASEOS_PATH/tools"
NAME="baseos-my355-$BASEOS_VERSION"
OUT="$B/baseos-my355.img"

eval "$(python3 "$TOOLS"/mkgpt.py --shell)"
TEXT_BASE=$(sed -n 's/^CONFIG_TEXT_BASE=//p' "$BUILD_DIR"/uboot-*/.config)
KREL=$(cat "$BUILD_DIR"/linux-*/include/config/kernel.release)

python3 "$TOOLS"/mkfit.py uboot "$B"/vendor-uboot.img "$B"/u-boot.bin "$B"/uboot.itb \
    --uboot-load "$TEXT_BASE"
python3 "$TOOLS"/mkfit.py boot "$B"/Image "$B"/rk3566-miyoo-flip.dtb "$B"/boot.itb \
    --release "$KREL" --root "$MY355_ROOT_DEV" --slot-sectors "$MY355_BOOT_SLOT_SECTORS"

# An update writes a whole slot, so overflowing one would corrupt the other.
fits() { # file sectors
    [ "$(wc -c < "$1")" -le $(($2 * 512)) ] || { echo "$1 overflows its slot" >&2; exit 1; }
}
fits "$B"/uboot.itb "$MY355_UBOOT_SLOT_SECTORS"
fits "$B"/boot.itb "$MY355_BOOT_SLOT_SECTORS"
fits "$B"/rootfs.erofs "$MY355_ROOTFS_SLOT_SECTORS"

rm -f "$OUT"; : > "$OUT"
python3 "$TOOLS"/mkgpt.py "$OUT"
put() { dd if="$1" of="$OUT" bs=512 seek="$2" conv=notrunc status=none; }
put "$B"/uboot.itb "$MY355_UBOOT_START"
put "$B"/boot.itb "$MY355_BOOT_START"
put "$B"/rootfs.erofs "$MY355_ROOTFS_START"

# data carries the preloader installer, as the only filesystem here stock can
# mount (docs/boot-chain.md); stock 5.10 has no orphan_file.
D="$BUILD_DIR"/data
rm -rf "$D" && mkdir "$D"
python3 "$BR2_EXTERNAL_BASEOS_PATH"/board/my355/preloader-installer/mkfwimg.py "$D"/miyoo355_fw.img
mke2fs -q -F -t ext4 -O ^orphan_file -b 4096 -L data -d "$D" \
    -E offset=$((MY355_DATA_START * 512)) "$OUT" $((MY355_DATA_SECTORS / 8))

# Empty: first boot reformats it at full size.
rm -f "$B"/primary.img
truncate -s $(((MY355_PRIMARY_SECTORS - 2048) * 512)) "$B"/primary.img
mkfs.exfat -L BASEOS "$B"/primary.img > /dev/null
put "$B"/primary.img "$MY355_PRIMARY_START"
rm "$B"/primary.img

python3 "$TOOLS"/mkupdate.py "$OUT" my355 "$BASEOS_VERSION" "$BASEOS_BUILD" "$B/$NAME.bosupd"
python3 - "$B/$NAME.img.zip" "$OUT" <<'EOF'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[2], "baseos-my355.img")
EOF
(cd "$B" && sha256sum "$NAME.img.zip" "$NAME.bosupd" > SHA256SUMS)
