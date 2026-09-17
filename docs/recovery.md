# NAND backup and recovery

How to back up internal flash, how to put it back, and what the ways back to a
fully stock device are. Read this before writing anything to `mtd5` — it is the
one region where a mistake costs a USB recovery.

Installing BaseOS changes exactly one thing in internal storage: the 2 MiB
preloader in `mtd5` ([boot chain](boot-chain.md)). The card installer copies your
original to the card before it erases anything, so the file named below is
normally already in your hands.

## Taking a backup

From a running stock system over adb. `nanddump` and `base64` are both in the
stock rootfs; the decode happens on the host, so nothing is written to the
device — not even to tmpfs:

```sh
for n in 0 1 2 3 4 5; do
  adb shell "base64 /dev/mtdblock$n" | base64 -d > "mtd$n.img"
done
```

(`adb exec-out` returns empty on this adbd and `adb shell` mangles binary, hence
base64.) Check each file against the device before trusting it:

```sh
adb shell "md5sum /dev/mtdblock0 /dev/mtdblock1 /dev/mtdblock2 /dev/mtdblock3 /dev/mtdblock4 /dev/mtdblock5"
md5 mtd*.img          # md5sum on Linux
```

`prepare-stock.sh` reads three of these, and expects them named as its own
backup was — `mtd1-uboot.img`, `mtd2-boot.img`, `mtd3-rootfs.img` — in one
directory:

```sh
./prepare-stock.sh ~/my-flip-nand-backup
```

`mtd5` is the preloader, and is the file the rest of this page is about.

## Putting the preloader back

Either from a running stock system (or ROCKNIX) over adb:

```sh
flash_erase /dev/mtd5 0 0 && nandwrite -p /dev/mtd5 mtd5-spl.img
md5sum /dev/mtd5ro          # must equal the image — check BEFORE rebooting
```

The file to write is your own backup, or the `mtd5-original-<hash>.img` the card
installer left on the card's BASEOS volume. Stage it in `/tmp` (tmpfs) and check
its md5 there first, so a failed write never needs a host transfer to retry.
While the device is still booted the write can be repeated indefinitely, so the
only real hazard is power loss between the erase and a verified write.

> **Do not restore from the RE wiki's `preloader.img`.** It differs from this
> unit by 188,698 bytes — it carries an older SPL (Nov 02 2024) with a
> *different, narrower* `spl-boot-order` ([hardware](hardware.md)). Restoring it
> would silently downgrade the preloader.

## If the device does not start at all

Realistically this only happens if power was lost during the write. Put the Flip
on its charger and try again first, with the SD card removed.

If the screen stays dark, the bootrom found no valid preloader and the device is
in USB **MASKROM** mode. That is recoverable, not bricked: RKDevTool restores it
over USB, following the
[Miyoo Flip unbricking guide](https://github.com/spruceUI/spruceOS/wiki/16.-Miyoo-Flip-Unbricking).
It has been done on this unit. The recovery package is a Dec 2024 full image, so
later firmware has to be reapplied afterwards.

A *valid* preloader that hangs is the same procedure, with MASKROM forced.

## This unit's backup

The reference backup the rest of the docs are measured against, taken
2026-08-19 and re-verified identical after every boot experiment:

```
62b1b1b5a860d534452921104ccfb1d3  mtd0-vnvm.img
eaadbe9d17db3805cac364ab4a935077  mtd1-uboot.img
7173ee8c08cebf885b81634030ae1cd2  mtd2-boot.img
f4fe4c713c5257e1a6c727b026892962  mtd3-rootfs.img
ef859074981742f24577e1f900ac3d95  mtd4-userdata.img
de5354838f9d878f088cae745cea9896  mtd5-spl.img   <-- preloader
```

## Corrections to the RE wiki

The [Miyoo Flip mainline RE wiki](https://github.com/Zetarancio/Miyoo-Flip-Mainline-Linux-Reverse-Engineering)
is the reference for this device, and two of its statements do not hold on this
firmware:

1. *"stock does not expose this region as `/dev/mtd*`"* — this firmware exposes
   the preloader as `mtd5` (offset 0, 2 MiB), and ships
   `flash_erase`/`nandwrite`. The stock↔ROCKNIX switch is fully
   software-reversible from stock, without the `/dev/mem` PreloaderEraser app.
2. The checked-in `preloader.img` is not representative: SPL build date and
   `u-boot,spl-boot-order` both differ from this 2025 unit
   ([hardware](hardware.md)).

Also worth knowing: the "device-specific" ROCKNIX artifact ships **all 16**
RK3566/RK3568 device trees and one shared quartz64-a-based U-Boot. Per-device
selection happens at the `extlinux.conf` `FDT` line, which on the 20260710 build
defaults to `rk3566-powkiddy-x55.dtb` and must be repointed.
