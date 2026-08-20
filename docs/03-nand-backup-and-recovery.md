# my355 · NAND backup and recovery

The backup this work depends on, how it was taken, and how to get back to stock.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Provenance of the NAND backup

Captured over adb by streaming `base64 /dev/mtdblock$N` and decoding on the host —
**no writes to the device**, not even to tmpfs. (`adb exec-out` returns empty on this
adbd; `adb shell` mangles binary, hence base64.)

Every partition was verified identical to the device, and re-verified identical after
both boot experiments:

```
62b1b1b5a860d534452921104ccfb1d3  mtd0-vnvm.img
eaadbe9d17db3805cac364ab4a935077  mtd1-uboot.img
7173ee8c08cebf885b81634030ae1cd2  mtd2-boot.img
f4fe4c713c5257e1a6c727b026892962  mtd3-rootfs.img
ef859074981742f24577e1f900ac3d95  mtd4-userdata.img
de5354838f9d878f088cae745cea9896  mtd5-spl.img   <-- preloader
```

Restore the preloader from a stock or ROCKNIX shell:

```sh
flash_erase /dev/mtd5 0 0 && nandwrite -p /dev/mtd5 mtd5-spl.img
```

> **Do not restore from the RE wiki's `preloader.img`.** It differs from this unit by
> 188,698 bytes — it carries an older SPL (Nov 02 2024) with a *different, narrower*
> `spl-boot-order` ([device reference](00-device-and-boot-chain.md)). Restoring it would silently downgrade the preloader.

---

## Corrections to the RE wiki

1. *"stock does not expose this region as `/dev/mtd*`"* — this firmware exposes the
   preloader as `mtd5` (offset 0, 2 MiB), and ships `flash_erase`/`nandwrite`. The
   stock↔ROCKNIX switch is fully software-reversible from stock, without the
   `/dev/mem` PreloaderEraser app.
2. The checked-in `preloader.img` is not representative: SPL build date and
   `u-boot,spl-boot-order` both differ from this 2025 unit ([device reference](00-device-and-boot-chain.md), [backup & recovery](03-nand-backup-and-recovery.md)).

Additionally, the "device-specific" ROCKNIX artifact ships **all 16** RK3566/RK3568
device trees and one shared quartz64-a-based U-Boot; per-device selection happens at
the `extlinux.conf` `FDT` line, which on the 20260710 build defaults to
`rk3566-powkiddy-x55.dtb` and must be repointed.

---

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md)
