# my355 · Port plan

What to build next and which decisions are still open.

**Boot chain: done.** A card built by [06](06-card-image-build.md) boots this
device from SD to userspace, with stock fallback intact. Option **A** below is
therefore in progress; option **B** is unblocked but not chosen.

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

Ordered by what currently blocks progress.

- **The issues seen after the first NextUI hand-off.** It launches; behaviour
  differences are the next thing to characterise against the compatibility table
  in [08](08-rootfs.md).
- **Intermittent hang on the boot logo, with the logo turning pixelated.** Random,
  on both the SD and the NAND path. Prime suspect was GammaLoader's 2021 DDR blob;
  the unit was returned to its own V1.18 on 2026-08-22, so this now needs sustained
  observation to confirm — see the [investigation log](05-investigation-log.md).
- **Ship our own U-Boot.** The largest remaining boot-time lever, worth 1.2–1.7 s.
  Evaluated 2026-08-22 and **shelved**: feasible without reverse engineering, but
  only at the cost of a dark panel until the kernel comes up, because mainline
  U-Boot has no VOP2 driver — see [09](09-uboot.md).
- **Find the real resource-size threshold.** 465 408 bytes boots, 943 616 hangs
  U-Boot before display init. The build stays under the proven figure, but the
  actual limit is unknown and worth pinning down.
- **Root read-only.** The card mounts root `rw`; H700 targets read-only with
  writable state on `/data`.
- **Which card holds the frontend.** BaseOS takes the right slot (the only
  boot-capable one), so a NextUI card moves to the left and BaseOS mounts it at
  `/mnt/SDCARD` — or falls back to its own `primary` partition, as H700 does
  ([docs/01](../upstream-h700/docs/01-rootfs-and-init.md) §5 step 8a). NextUI itself is slot-agnostic:
  nothing in `my355.sh` or `MinUI.pak/launch.sh` names a block device.
- **Which vendor daemons NextUI actually needs** for brightness, battery and
  Bluetooth. H700 needed three shims (`systemctl`, `timedatectl`,
  `setBluetooth.sh`); the my355 surface looks smaller but is unmeasured.
- ~~**Boot budget for a real card.**~~ **Done (2026-08-23).** Hand-off 4.98 s
  against stock's 15.79 s, first frame 7.93 s against 31.50 s, pre-kernel 3.13 s
  from the card against 4.30 s from NAND. Left open: why NextUI's `launch.sh` costs
  12.45 s on stock and 0.89 s here ([boot budget](01-boot-budget.md)).
- **Root read-only.** The card currently mounts root `rw`. H700 targets a
  read-only root with writable state on `/data` ([docs/06](../upstream-h700/docs/06-status-and-lessons.md)).
- **A/B updates.** Slot B is reserved but `baseos-update`, `mkupdate.py` and
  `gptslot` are not ported.

## Should BaseOS build its own preloader?

No. The patched stock preloader works, is verified on this unit, costs nothing
measurable when no card is present, and leaves DDR scaling intact. Replacing it means
writing first-stage code — the one region where a mistake costs a MASKROM recovery —
for benefits that are now largely gone:

1. **Distribution and provenance — largely resolved.** This was the strongest argument
   while the plan was to ship GammaLoader's prebuilt binary. It no longer applies the
   same way: `tools/mkpreloader.py` redistributes nothing, it patches nine device
   tree properties into **the user's own dump**. What remains is a delivery problem
   rather than a licensing one — see below.
2. **A measured boot-time gain — no.** Measured at 3.114 s pre-kernel against 3.118 s
   under GammaLoader. There is no penalty to recover.
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

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
