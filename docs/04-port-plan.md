# my355 · Port plan

What to build next and which decisions are still open.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Two possible ports

Experiment 4 booted a *mainline* kernel from SD on this hardware, which opens a second
strategy. Both are viable over the same `mtd1` + extlinux mechanism; the choice is
about which kernel BaseOS stands on.

| | **A — stock kernel** (H700 BaseOS model) | **B — mainline kernel** (ROCKNIX model) |
|---|---|---|
| kernel / DTB | vendor 5.10.160 from `mtd2` | mainline 7.0+ with `rk3566-miyoo-flip.dtb` |
| hardware support | complete by construction, vendor-tested | good but tracked by the ROCKNIX effort — see the RE wiki status table |
| BaseOS parity | matches H700 doctrine: keep the vendor kernel byte-for-byte, replace only userland | departs from it |
| userland | BusyBox + harvested glibc 2.36 from the stock squashfs | same approach, different libc source |
| boot budget | kernel phase ~1.61 s measured ([boot budget](01-boot-budget.md)) | unmeasured on this device |
| risks | kernel is a 2025 BSP fork, no upstream fixes | DMC, suspend and WiFi carry out-of-tree pieces |
| card layout | extract `Image` + DTB from `mtd2`'s Android boot image into extlinux form | ROCKNIX's `/KERNEL` + `/device_trees/` as-is |

Neither is blocked by anything found so far. **A** is the smaller step and preserves the
"perfect hardware support for free" property that makes the H700 port cheap; **B** gets
mainline, an actively maintained DTS, and the option of tracking ROCKNIX's work — at
the cost of owning kernel bring-up.

Open question for **B**: Experiment 4's ROCKNIX boot reached the kernel and printed logs
but never reached its UI. The likely cause is local to that test card rather than to
ROCKNIX — the GPT partition added at LBA 4292608 sits immediately behind ROCKNIX's
`storage` partition (ends 4292607), and ROCKNIX expands storage to fill the card on
first boot. The card's payload was verified undamaged afterwards (`KERNEL` and `SYSTEM`
both match the shipped `.md5` manifests). Re-test with those added partitions removed
before drawing any conclusion about mainline on this device.

## Open questions

- **Which port — stock kernel (A) or mainline (B)?** See [port plan](04-port-plan.md). Both are now unblocked:
  Experiment 6 boots either from SD, and ROCKNIX (mainline 7.0+ with
  `rk3566-miyoo-flip.dtb`) reaches its UI on this hardware.
- **Boot budget for a real BaseOS card.** Unmeasured. The interesting figure is
  pre-kernel time when the card *is* bootable — GammaLoader's SPL plus a lean mainline
  U-Boot should beat stock's ~2.95 s U-Boot substantially, but nobody has measured it.
- **Cost of an inserted non-bootable card.** One sample showed pre-kernel 7.18 s with a
  NextUI card inserted, against 4.31 s with none — i.e. ~2.9 s of SD probing that
  finds no `uboot` partition. Single measurement, unconfirmed, and irrelevant to a
  BaseOS card (which is bootable), but it would affect users who keep a plain data card
  in the right slot.
- **Should BaseOS ship its own preloader instead of GammaLoader's?** See [port plan](04-port-plan.md).
- Why the *stock* SPL cannot boot from SD, when GammaLoader's older one can with the
  same card, remains undetermined ([investigation log](05-investigation-log.md)). Now academic.
- Kernel cost breakdown: `rtl8733bu` probes for ~0.7 s of the 1.61 s kernel phase.
  Making it a module would break "vendor kernel untouched"; quantify before deciding.

## Should BaseOS build its own preloader?

Not yet. GammaLoader's works, is verified on this unit, costs nothing measurable when no
card is present, and leaves DDR scaling intact. Replacing it means writing first-stage
code — the one region where a mistake costs a MASKROM recovery — for benefits that are
currently hypothetical.

Reasons it may become worth doing later, roughly in order of strength:

1. **Distribution.** BaseOS is a public project. Shipping a third party's prebuilt
   preloader raises provenance and GPL source-availability questions that building from
   Rockchip's public U-Boot would avoid. This is the strongest argument and it is about
   licensing, not engineering.
2. **A measured boot-time gain.** Only after [port plan](04-port-plan.md)'s budget measurement. GammaLoader's
   SPL is a 2021 build with DDR `V1.10`; a newer DDR blob might train faster. Currently
   there is no evidence of a penalty — the no-card figure is within noise of stock.
3. **Owning the boot order.** A custom SPL could list additional devices. Note the left
   slot is probably unreachable regardless: `spl_mmc_find_device` maps both
   `BOOT_DEVICE_MMC2` and `BOOT_DEVICE_MMC2_2` to **mmc index 1**, so both `dwmmc`
   nodes resolve to `fe2b0000` ([investigation log](05-investigation-log.md)).

Prerequisites before attempting it: the Rockchip U-Boot 2017.09 tree, a matching rkbin
DDR blob, correct IDB/`RKNS` packaging (magic at `0x20000` for SPI NAND, **not** sector
64 as on SD), emission of the `bootdev` ATAG, and a DDR blob that BL31 accepts. Each is
individually known; together they are a real piece of work, and every iteration is a
preloader write.

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md)
