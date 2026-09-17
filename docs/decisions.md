# Decisions

The choices this port rests on, why each was made, and what is still open. A
decision recorded here is one that would be expensive to revisit — everything
else lives in the page for the thing it affects.

## Settled

### Keep the vendor kernel, replace only the userland

The alternative was a mainline kernel, ROCKNIX-style: Experiment 4 booted one
from SD on this hardware ([history](history.md)), so it is available.

| | **stock kernel — chosen** | mainline kernel |
|---|---|---|
| kernel / DTB | vendor 5.10.160 from `mtd2` | mainline with `rk3566-miyoo-flip.dtb` |
| hardware support | complete by construction, vendor-tested | good, but tracked by the ROCKNIX effort |
| userland | BusyBox + harvested glibc 2.36 from the stock squashfs | same approach, different libc source |
| risks | a 2025 BSP fork, no upstream fixes | DMC, suspend and WiFi carry out-of-tree pieces |

The stock kernel is the smaller step and keeps perfect hardware support for
free. Rebuilding or replacing it is a design decision, not an implementation
detail: write it down here first.

One loose end if mainline is ever revisited: Experiment 4's ROCKNIX boot reached
the kernel but never its UI. The likely cause is local to that test card — the
GPT partition added at LBA 4292608 sat immediately behind ROCKNIX's `storage`
partition, whose first-boot expansion then had nowhere to go, and which never
retries. Re-test with the added partitions removed before concluding anything
about mainline here.

### Patch the user's preloader rather than ship one

The patched stock preloader works, is verified on hardware, costs nothing
measurable when no card is present, and leaves DDR scaling intact. Building our
own means writing first-stage code — the one region where a mistake costs a USB
recovery — for benefits that are largely gone:

1. **Distribution and provenance.** `tools/mkpreloader.py` redistributes nothing:
   it patches nine device tree properties into the user's own dump.
2. **Boot time — none to win.** 3.114 s pre-kernel against 3.118 s under
   GammaLoader's loader.
3. **Owning the boot order.** A custom SPL could list more devices, but the left
   slot is unreachable regardless: `spl_mmc_find_device` maps both
   `BOOT_DEVICE_MMC2` and `BOOT_DEVICE_MMC2_2` to mmc index 1, so both `dwmmc`
   nodes resolve to `fe2b0000` ([history](history.md)).

There is a fourth, decisive reason: the DDR blob is paired with the unit. One
shipped image forces ours onto every device, which is exactly how this unit came
to run a 2021 V1.10 blob against a V1.18-era BL31, and how it came to hang
intermittently on the boot logo until its own blob was restored.

Prerequisites, if it is ever attempted anyway: the Rockchip U-Boot 2017.09 tree,
a matching rkbin DDR blob, correct IDB/`RKNS` packaging (magic at `0x20000` for
SPI NAND, **not** sector 64 as on SD), emission of the `bootdev` ATAG, and a DDR
blob BL31 accepts. Each is individually known; together they are a real piece of
work, and every iteration is a preloader write.

### Keep the vendor U-Boot

Replacing it is the largest remaining boot-time lever — 1.2–1.7 s — and needs no
NAND write, because the card already carries the `uboot` partition. Evaluated and
**shelved**: mainline U-Boot has no VOP2 driver, so a boot logo means writing
one, and a dark panel until the kernel comes up is a worse product than a slower
boot. Tuning the vendor one from its device tree was tried and measured at 22 ms.
Both in [U-Boot](uboot.md).

### No signing key for updates

A key would be a single point of failure for every update, and these images carry
no secrets. Integrity is a SHA-256 per region, verified by reading back what was
written ([the card](card.md)).

### Two cards, not one

BaseOS takes the right slot, because it is the only slot the SPL boots from, and
reads the frontend from a card in the left slot. One card works too — the boot
card's own FAT volume is the fallback — but two keeps games and saves on a card
that can be pulled, reformatted or replaced without touching the one that boots
the device. NextUI is slot-agnostic: nothing in `my355.sh` or
`MinUI.pak/launch.sh` names a block device ([rootfs](rootfs.md)).

## Open

- **Root is mounted `rw`.** A read-only root with writable state on `/data` is
  the target; nothing on the card depends on a writable root today except the
  update trial state, which already lives on `/data`.
- **The real resource-size threshold.** 465 408 bytes boots, 943 616 hangs
  U-Boot before display init. The build stays under the proven figure, but the
  actual limit is unknown ([the card](card.md)).
- **spruceOS as a frontend.** Its card would be mounted and its `updater`
  executed, but whether it finds the userland it expects in the harvest is
  unchecked.
