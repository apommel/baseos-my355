# my355 — BaseOS on the Miyoo Flip

Porting notes for the **Miyoo Flip** (Rockchip RK3566, `MIYOO RK3566 355 V10 Board`),
NextUI platform id **`my355`**.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Status

**The boot chain is complete and verified on hardware.** A BaseOS card boots the
device from SD all the way to userspace: SPL → our U-Boot → `boot_android` → the
vendor kernel → our ext4 root → our init. The stock OS still boots when no
bootable card is present.

This costs a **2 MiB** change to internal NAND (the preloader) and nothing else —
stock U-Boot, kernel, rootfs and BL31 are all untouched. ROCKNIX also boots this
way, so the mainline path is open too.

The card applies that change itself: stock's own firmware-update mechanism runs an
installer off the card, which patches the `mtd5` already on the unit and reboots.
No preloader binary is redistributed. See [SD boot](02-sd-boot.md).

**BaseOS boots on this device and adb works over USB.** PID 1 is BusyBox init,
`rcS` completes in **50 ms**, the harvested vendor libraries execute
(`wpa_supplicant v2.9`, `dbus-daemon 1.12.20`), and `/proc/cmdline` reports
`storagemedia=sd`.

NextUI has been launched from it successfully. With the kernel stored gzipped,
BaseOS reaches frontend hand-off in **4.98 s** against stock's **15.79 s**, and a
first NextUI frame in **6.87 s** against stock's **31.50 s** (both measured
2026-08-23) — and boots from SD faster than stock does from internal NAND. See the
[boot budget](01-boot-budget.md) and the [port plan](04-port-plan.md).

**As of 2026-08-20 this unit runs:**

| | |
|---|---|
| `mtd5` preloader | **this unit's own, `/pinctrl` patched** (`ccc279738fa0123e914e15caca36412c`) |
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
| [01 · Boot budget](01-boot-budget.md) | Stock and BaseOS measured end to end, how to read the two clocks, and what is left to win. |
| [02 · SD boot](02-sd-boot.md) | The working mechanism, the card recipe, and the gotchas. |
| [03 · NAND backup and recovery](03-nand-backup-and-recovery.md) | Hashes, provenance, how to get back to stock. |
| [04 · Port plan](04-port-plan.md) | Stock-kernel vs mainline, open questions, whether to build our own preloader. |
| [05 · Investigation log](05-investigation-log.md) | Experiments, SPL disassembly, and every retracted theory. |
| [06 · Building a BaseOS card](06-card-image-build.md) | Card layout, boot image surgery, build and flash. |
| [07 · Bring-up and diagnostics](07-bringup-and-diagnostics.md) | How to debug a device that can print nothing. |
| [08 · The rootfs](08-rootfs.md) | Harvest, overlay, init, adb, NextUI compatibility. |
| [09 · U-Boot](09-uboot.md) | Tuning it (tried, 22 ms) and replacing it (shelved). |

## If you only read one thing

The stock preloader **cannot** boot this device from SD, and no card layout changes
that — three hardware experiments rule out partition naming, SD power, and FIT format
in turn. A preloader with a working `/pinctrl` can, and it looks up a GPT partition named
`uboot` and reads the FIT from its first sector. Installing **only** that preloader
(2 MiB to `mtd5`, leaving stock U-Boot, kernel and rootfs untouched) gives SD-if-present
with stock fallback, no measurable boot-time cost, and DDR scaling intact.

Details in [SD boot](02-sd-boot.md). Building a card that uses it is
[06](06-card-image-build.md); the dead ends are in the
[investigation log](05-investigation-log.md).

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
