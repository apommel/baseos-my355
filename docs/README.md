# my355 — BaseOS on the Miyoo Flip

Porting notes for the **Miyoo Flip** (Rockchip RK3566, `MIYOO RK3566 355 V10 Board`),
NextUI platform id **`my355`**.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Status

SD boot works. The device boots from an SD card when one carries a `uboot` GPT
partition, and falls back to the stock OS otherwise — at the cost of a **2 MiB**
change to internal NAND (the preloader) and nothing else. ROCKNIX boots to its UI
this way. A BaseOS card has not been built yet; see the [port plan](04-port-plan.md).

**As of 2026-08-20 this unit runs:**

| | |
|---|---|
| `mtd5` preloader | **GammaLoader's** (`2252285dfd55072212568d640712fb77`) |
| everything else in NAND | stock, byte-identical to the 2026-08-19 backup ([backup & recovery](03-nand-backup-and-recovery.md)) |
| behaviour | SD card with a `uboot` partition → boots from SD; otherwise → stock OS |
| cost when no card present | none measurable (4.31 s vs 4.26–4.29 s baseline) |
| DDR scaling | intact, all four FSPs |

To return fully to stock: restore `mtd5-spl.img` ([backup & recovery](03-nand-backup-and-recovery.md)) with `flash_erase` + `nandwrite`
from either the stock system or ROCKNIX.


## Documents

| | |
|---|---|
| [00 · Device and boot chain](00-device-and-boot-chain.md) | Hardware, MTD layout, kernel config, SD slot mapping, SPL boot order. Start here. |
| [01 · Boot budget](01-boot-budget.md) | Where the ~18 s to frontend goes, and what a port can reclaim. |
| [02 · SD boot](02-sd-boot.md) | The working mechanism, the card recipe, and the gotchas. |
| [03 · NAND backup and recovery](03-nand-backup-and-recovery.md) | Hashes, provenance, how to get back to stock. |
| [04 · Port plan](04-port-plan.md) | Stock-kernel vs mainline, open questions, whether to build our own preloader. |
| [05 · Investigation log](05-investigation-log.md) | Experiments 1–6, SPL disassembly, and every retracted theory. |

## If you only read one thing

The stock preloader **cannot** boot this device from SD, and no card layout changes
that — three hardware experiments rule out partition naming, SD power, and FIT format
in turn. GammaLoader's older preloader can, because it looks up a GPT partition named
`uboot` and reads the FIT from its first sector. Installing **only** that preloader
(2 MiB to `mtd5`, leaving stock U-Boot, kernel and rootfs untouched) gives SD-if-present
with stock fallback, no measurable boot-time cost, and DDR scaling intact.

Details in [SD boot](02-sd-boot.md); the dead ends in the
[investigation log](05-investigation-log.md).

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md)
