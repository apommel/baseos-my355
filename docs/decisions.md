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

### Mainline U-Boot, since 0.7.0

Replacing it needs no NAND write, because the card already carries the `uboot`
partition, and it fails safe: a bad FIT sends the SPL on to stock in NAND. The
1.2–1.7 s once projected for it is **refuted**, and the first build to boot
(2026-09-05) was 0.16 s *slower*, because it handed the kernel 816 MHz where the
vendor hands 1104. Eight changes later — that clock, a zstd kernel, the card
driven at the 50 MHz it only claimed to use, the data cache on before
relocation, the GPT held in the block cache, decompression at 1800 MHz, the
Flip's own control tree and the zstd decoder at `-O2` — it reaches `Run /init`
**1.8 s** ahead of the vendor path.

It costs the early boot logo — mainline U-Boot has no VOP2 driver, so `rcS`
draws it, on the panel at 2.00 s against ~1.0 s — and the charge screen (the
charge LED and the low-battery guard are kept). And it has to do by hand what the vendor
kernel silently relied on the vendor U-Boot for: the OP-TEE reservation, the
display plane assignment (without it the panel stays black under NextUI) and the
fuel gauge (without it the battery reads 0% when full). Each was found by its
failure, so there may be a fourth.

One of them turned into a gain. Giving each display a VOP2 window of its own
runs the panel and HDMI at the same time with independent content, and makes
hot-plug and hot-unplug work. Stock cannot: it disables the panel to use a TV,
and has to reboot to switch.

It became the default on 2026-09-19 and first shipped in 0.7.0;
`MY355_UBOOT=vendor` still builds the vendor path. It replaces U-Boot proper and
nothing else: BL31, OP-TEE and the SPL's control tree stay the vendor's,
byte-for-byte. Its seven U-Boot patches and its control tree are ours to carry;
three of the patches — the RK3568 SD clock (an upstream bug), the data cache
before relocation and the 1608/1800 MHz CPU rates — are worth sending upstream.
The patches, the control tree and the measurements are in [U-Boot](uboot.md)
Part 3; tuning the vendor U-Boot from its device tree instead was tried and
measured at 22 ms (Part 1).

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

### A read-only root

The kernel mounts the rootfs `ro`. Everything that changes at runtime already
lived elsewhere: `/data` for the log, keys, machine-id and update state; tmpfs
for `/tmp`, `/run` and `/var`; the card's `/userdata` bind for the frontend's
settings. NextUI never needed a writable root, since on stock it runs on
squashfs. What it buys: a power-off that skips `rcK` cannot dirty or corrupt
the OS, the root never replays a journal, a stray write fails with `EROFS`
instead of shadowing the card, and the running slot stays byte-identical to its
image ([rootfs](rootfs.md)).

## Open

- **The real resource-size threshold** (vendor U-Boot path only). 465 408 bytes
  boots, 943 616 hangs U-Boot before display init. The build stays under the proven figure, but the
  actual limit is unknown ([the card](card.md)).
- **spruceOS as a frontend.** Its card would be mounted and its `updater`
  executed, but whether it finds the userland it expects in the harvest is
  unchecked.
