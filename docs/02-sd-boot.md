# my355 · SD boot — how it works

How this device boots from an SD card when one is present and falls back to the stock OS
when it is not. This is the **implemented, verified** mechanism. For how it was arrived
at — including several wrong turns — see the [investigation log](05-investigation-log.md).

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

GammaLoader (`GammaLoaderMiyooFlip.zip`) is a stock **App** that installs in two stages:
`launch.sh` writes `GammaLoader.img` over `/dev/mtdblock2` (the `boot` partition under
stock's `mtdparts`) and reboots; the resulting Android recovery then runs

```sh
gzip -dc /mtdblock0.img.gz > /tmp/mtdblock0.img   # 2 MiB preloader
gzip -dc /boot.img.gz      > /tmp/mtdblock3.img   # replacement boot image
dd if=/tmp/mtdblock0.img of=/dev/block/mtdblock0  # preloader  (its own mtdparts)
dd if=/tmp/mtdblock3.img of=/dev/block/mtdblock3  # boot
reboot
```

Its real product is a **replacement preloader**: `U-Boot SPL 2017.09-ga1f6fc00a0-210413`
(Apr 13 2021), DDR `V1.10`, with

```
u-boot,spl-boot-order = "/dwmmc@fe2b0000", "/sdhci@fe310000", "/nandc@fe330000",
                        "/sfc@fe300000/flash@0", "/sfc@fe300000/flash@1";
```

— SD first, SPI NAND last, i.e. SD-with-stock-fallback by construction.

## Why it does not work with ROCKNIX — confirmed from the binary

The two SPLs diverge at exactly one point, in `spl_mmc.c`:

```
GammaLoader (Apr 2021)                     Stock (Dec 2024)
0x3250c  part_get_info_by_name("uboot")    0x3160c  part_get_info_by_name("uboot")
0x32510  ok -> load from info.start        0x31610  ok -> load from info.start
0x32514  "spl: partition error"            0x31614  "spl: partition error"
0x32520  mov w19, #-0x26   (-ENOSYS)       0x31628  mov x2, #0x4000
0x32524  b   -> RETURN FAILURE             0x31630  bl  -> load raw sector 0x4000
```

**GammaLoader's SPL has no raw-sector fallback.** Without a GPT partition *named*
`uboot` it returns `-38` and never looks at sector `0x4000` — which is precisely where
ROCKNIX places `u-boot.itb`. ROCKNIX cards carry only `system` and `storage`, so the
lookup fails and the SPL falls through to internal NAND.

## The fix

Create a GPT partition named **`uboot` starting at sector 16384** on the card. **No data
needs to be written into it** — ROCKNIX's `u-boot.itb` is already there; the partition
entry merely gives `part_get_info_by_name` something to find, and `info.start`
(loaded at `0x32578`) then points at the existing FIT. Sectors 16384–32767 are free on a
ROCKNIX card (partition 1 starts at 32768).

This originates as an untested community suggestion; the static analysis above
corroborates it. **Not yet verified on hardware.**

It also explains Experiment 2: adding a `uboot` partition was the right idea applied to
the wrong SPL — stock's already has the fallback, so it changed nothing there.

## Recommended refinement: install the preloader only

GammaLoader's bundled `boot.img.gz` is **not this unit's kernel** — 12 916 788-byte
kernel with a 944 128-byte resource, versus 36 647 424 / 465 408 in `mtd2` here. Running
its full installer downgrades the kernel underneath a 2025-06-27 rootfs.

Since stock exposes the preloader as `mtd5` (offset 0, 2 MiB) and ships
`flash_erase`/`nandwrite`, the preloader can be written directly from the running stock
system, leaving everything else alone:

| partition | under this plan |
|---|---|
| `mtd5` preloader | **replaced** with GammaLoader's (2 MiB) |
| `mtd1` uboot | untouched — stock |
| `mtd2` boot | untouched — stock kernel |
| `mtd3` rootfs | untouched — stock + NextUI |

Result: card with a `uboot` partition at 16384 → boots from SD; no card, or a card
without one → falls through to `sfc/flash@0` → stock U-Boot → stock OS. This is the
required behaviour with a **2 MiB** NAND change and a community-proven SPL, and it
sidesteps the unexplained U-Boot hang of Experiment 5 entirely, because U-Boot is never
modified.

Risks to check before doing it:

1. **DDR blob / BL31 pairing.** GammaLoader ships DDR `V1.10`; stock BL31 lives in the
   untouched `mtd1`. BL31 checks loader/trust versions before enabling DMC
   (`loader&trust unmatch!!!`). Mismatch would disable DDR frequency scaling — a
   power/performance regression, not a boot failure. Verify against `rockchip-dmc` in
   dmesg afterwards.
2. **ATAG compatibility.** GammaLoader's SPL is the same Rockchip 2017.09 family as
   stock's, so the `bootdev` ATAG stock U-Boot expects should be emitted. Unverified.
3. **Recovery.** A bad preloader is the one failure with a real chance of needing
   MASKROM. `mtd5-spl.img` ([backup & recovery](03-nand-backup-and-recovery.md)) is the verified restore image for this unit — **not**
   the RE wiki's `preloader.img`, which is a different SPL build.

## Experiment 6 — GammaLoader preloader only (2026-08-20) — **works**

Only `mtd5` written: `flash_erase /dev/mtd5 0 0 && nandwrite -p /dev/mtd5
gammaloader-preloader.img` from the running stock system (`mtd5` is `MTD_WRITEABLE`,
flags `0x400`, **0 bad blocks**). Readback verified byte-exact,
md5 `2252285dfd55072212568d640712fb77`. GammaLoader's own installer was **not** run, so
its foreign `boot.img` never touched `mtd2`.

| partition | after | |
|---|---|---|
| `mtd5` preloader | `2252285d…` | **replaced** |
| `mtd0` vnvm | `62b1b1b5…` | unchanged |
| `mtd1` uboot | `eaadbe9d…` | unchanged — stock U-Boot **and BL31** |
| `mtd2` boot | `7173ee8c…` | unchanged — 2025 vendor kernel |
| `mtd3` rootfs | `f4fe4c71…` | unchanged — stock + NextUI |
| `mtd4` userdata | `ef859074…` | unchanged |

**All three cases behave correctly:**

| card | result |
|---|---|
| none | stock → MainUI. Pre-kernel **`[ 4.313678]`**, against a 4.26–4.29 s stock-preloader baseline — **no measurable cost** |
| ROCKNIX + `uboot` partition | **boots from SD** |
| NextUI (no `uboot` partition) | falls through to stock → NextUI, normally |

`/proc/cmdline` reports `storagemedia=mtd`, `root=/dev/mtdblock3` on the fallback path —
so **GammaLoader's SPL does emit the Rockchip `bootdev` ATAG** that stock U-Boot needs.
That was the one risk that could not be settled from the binaries; it is now settled.

## DDR scaling survives the older blob

The other unresolved risk. GammaLoader ships DDR `V1.10` (2021) against this unit's
BL31 (TF-A v2.3-607-gbf602aff1, Jun 2023). Measured after the swap:

```
rockchip-dmc dmc: current ATF version 0x102
rockchip-dmc dmc: normal_rate = 780000000   suspend_rate = 324000000
rockchip-dmc dmc: boost_rate  = 1056000000  performance_rate = 1056000000
devfreq/dmc available: 324000000 528000000 780000000 1056000000
governor: dmc_ondemand    cur_freq: 324000000
```

All four FSPs, `dmc_ondemand` active, idling at 324 MHz exactly as the stock log does,
and **no `loader&trust unmatch`**. The pairing is fine. This is consistent with
GammaLoader's design — its installer never writes the `uboot` partition where BL31
lives, so it is built to coexist with whatever stock BL31 is present. BL31 is
byte-identical (`0de046d4…`) between this unit's firmware and the RE wiki's May 2025
unpack, so that assumption holds across releases.

## The `uboot` partition tip — confirmed twice

A community suggestion (via Discord, reportedly untested) held that creating a `uboot`
GPT partition at sectors 16384–32767 **without writing data into it** would make
GammaLoader work with ROCKNIX. Both confirmations:

- **Statically** — the disassembly above: no raw-sector fallback, so the name lookup is
  the only path in.
- **On hardware** — Experiment 6: a ROCKNIX card carrying such a partition boots.

`info.start` is 16384, ROCKNIX already places `u-boot.itb` there, so the partition entry
alone is sufficient. Note the partition deliberately **overlaps existing data**; that is
the point.

## Card recipe

For any SD-bootable OS on this device once GammaLoader's preloader is installed:

| | |
|---|---|
| `uboot` GPT partition | starts at sector **16384**; contents may be pre-existing |
| U-Boot FIT | at that sector — ROCKNIX's mainline `u-boot.itb` works; OP-TEE is **not** required (Exp. 3, Exp. 6) |
| OS | whatever that U-Boot boots — ROCKNIX uses `/extlinux/extlinux.conf` on partition 1 |

## Gotcha: ROCKNIX's storage resize runs exactly once

ROCKNIX expands its `STORAGE` partition to fill the card on **first boot only**, then
writes `.configured`. During Experiment 4 the card had a partition at LBA 4292608,
immediately behind `storage`, so the expansion had nowhere to go. `STORAGE` stayed at
32 MiB, the config tree filled it to **100% with 0 bytes free**, EmulationStation could
not write `es_settings.cfg`, and the UI never appeared. Removing the blocking partition
afterwards did not help — the resize never retries.

Diagnosed by putting the card in the **left slot** (not in GammaLoader's boot order, so
stock boots) and reading the ext4 `STORAGE` partition over adb.

Fixed by re-flashing the image and re-adding only the `uboot` partition at 16384–32767 —
which sits *before* partition 1 and leaves the space behind `storage` clear.
**ROCKNIX then boots to its UI.** Keep any added partitions below LBA 32768.

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md)
