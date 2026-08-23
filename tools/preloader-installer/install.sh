#!/bin/sh
# BaseOS preloader installer. Reads this unit's own mtd5, repairs /pinctrl in the SPL
# device tree, writes it back. Ships no preloader binary: the DDR blob and SPL code
# stay whatever this unit shipped with. See docs/02-sd-boot.md.
HERE="$(dirname "$0")"
# /media/sdcard0 is a symlink; /proc/mounts carries the target, so resolve before use.
CARD="${CARD:-$(pwd)}"
CARD=$(cd "$CARD" 2>/dev/null && pwd -P) || CARD="${CARD:-$(pwd)}"

# Backup and log go on the card's FAT, which stock may not have mounted.
FATMNT=/tmp/baseos-fat
OUTDIR="$CARD"
CARDDEV=$(awk -v d="$CARD" '$2 == d { print $1 }' /proc/mounts)
case "$CARDDEV" in
    /dev/mmcblk*p*)
        for part in "${CARDDEV%p*}"p*; do
            blkid "$part" 2>/dev/null | grep -q 'TYPE="vfat"' || continue
            mkdir -p "$FATMNT"
            mount -t vfat "$part" "$FATMNT" 2>/dev/null && OUTDIR="$FATMNT"
            break
        done
        ;;
esac
LOG="$OUTDIR/baseos-preloader.log"
MTD=${MTD:-/dev/mtd5}
MIN_BATTERY=25

log() { echo "$*"; echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }
progress() { echo "$1" > /tmp/fwupdate_progress; }
finish() {
    sync
    mountpoint -q "$FATMNT" 2>/dev/null && umount "$FATMNT"
    progress 100; echo 1 > /tmp/fwupdate_done
    [ "${BOOT:-0}" = "1" ] && { sleep 2; reboot; }
    exit "${1:-0}"
}

log "--- BaseOS preloader installer $(date) ---"
progress 5

# Refuse unless the ground is safe.
grep -q '"spl"' /proc/mtd || { log "no spl partition; wrong device"; finish 1; }
[ "$(grep '"spl"' /proc/mtd | cut -c1-5)" = "mtd5:" ] || { log "spl is not mtd5"; finish 1; }
CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 0)
AC=0
for s in /sys/class/power_supply/*/online; do
    [ "$(cat "$s" 2>/dev/null)" = "1" ] && AC=1
done
if [ "$CAP" -lt "$MIN_BATTERY" ] && [ "$AC" != "1" ]; then
    log "battery $CAP% and no charger; refusing"; finish 1
fi
log "battery $CAP%, on charger $AC"

progress 10
dd if=${MTD}ro of=/tmp/baseos-orig.img bs=2048 2>/dev/null
BEFORE=$(sha256sum /tmp/baseos-orig.img | cut -c1-64)
log "mtd5 reads as $BEFORE"

progress 20
if ! AWK_SCRIPT="$HERE/fdtpatch.awk" sh "$HERE/patch-preloader.sh" \
        /tmp/baseos-orig.img /tmp/baseos-new.img >> "$LOG" 2>&1; then
    log "not patched (see log) - nothing was written"; finish 0
fi
AFTER=$(sha256sum /tmp/baseos-new.img | cut -c1-64)
log "patched image is $AFTER"

# A way back, on the card, before anything is erased.
progress 30
cp /tmp/baseos-orig.img "$OUTDIR/mtd5-original-$BEFORE.img" && sync
[ "$(sha256sum "$OUTDIR/mtd5-original-$BEFORE.img" | cut -c1-64)" = "$BEFORE" ] \
    || { log "backup to the card did not verify; refusing"; finish 1; }
log "original backed up to $OUTDIR"

if [ "${BASEOS_DRY:-0}" = "1" ]; then
    log "dry run - would erase $MTD and write the patched image"
    finish 0
fi

# The only irreversible window.
progress 40
n=0
while [ $n -lt 3 ]; do
    n=$((n + 1))
    log "flash attempt $n"
    flash_erase "$MTD" 0 0 >> "$LOG" 2>&1
    nandwrite -p "$MTD" /tmp/baseos-new.img >> "$LOG" 2>&1
    progress $((40 + n * 15))
    dd if=${MTD}ro of=/tmp/baseos-back.img bs=2048 2>/dev/null
    if [ "$(sha256sum /tmp/baseos-back.img | cut -c1-64)" = "$AFTER" ]; then
        # Rebooting only helps from the slot the SPL can boot.
        case "$CARDDEV" in
            /dev/mmcblk1p*) log "readback verified - rebooting into the card"; BOOT=1 ;;
            *) log "readback verified - move the card to the right-hand slot" ;;
        esac
        progress 95
        finish 0
    fi
    log "readback mismatch"
done

log "could not write the patched preloader; restoring the original"
n=0
while [ $n -lt 3 ]; do
    n=$((n + 1))
    flash_erase "$MTD" 0 0 >> "$LOG" 2>&1
    nandwrite -p "$MTD" /tmp/baseos-orig.img >> "$LOG" 2>&1
    dd if=${MTD}ro of=/tmp/baseos-back.img bs=2048 2>/dev/null
    if [ "$(sha256sum /tmp/baseos-back.img | cut -c1-64)" = "$BEFORE" ]; then
        log "original restored; device is exactly as it was"; finish 1
    fi
done
log "FAILED to restore - recover with RKDevTool, see docs/03-nand-backup-and-recovery.md"
finish 1
