# my355 · Investigation log

How SD boot was made to work, including the theories that turned out to be wrong. Kept
because the refutations are load-bearing — each rules out a mechanism someone would
otherwise retry. For the working result, see [SD boot](02-sd-boot.md).

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Change log

| date | event |
|---|---|
| 2026-08-19 | NAND backed up and verified over adb, no writes to device ([backup & recovery](03-nand-backup-and-recovery.md)) |
| 2026-08-19 | Exp. 1 — ROCKNIX card, right slot → stock booted |
| 2026-08-19 | Exp. 2 — added GPT partition `uboot` → stock booted; SPL disassembled |
| 2026-08-20 | Exp. 3 — device's own OP-TEE-bearing FIT on the card → stock booted; card-side causes exhausted ([investigation log](05-investigation-log.md)) |
| 2026-08-20 | Exp. 4 — patched `mtd1` (v1) → **ROCKNIX booted from SD**; fallback bug found; reverted |
| 2026-08-20 | Exp. 5 — patched `mtd1` (v2), fallback hardcoded → still hung with a non-bootable card; reverted ([investigation log](05-investigation-log.md)) |
| 2026-08-20 | GammaLoader disassembled — no raw-sector fallback; explains its ROCKNIX incompatibility ([SD boot](02-sd-boot.md)) |
| 2026-08-20 | Exp. 6 — **GammaLoader preloader only → all three cases correct; DDR scaling intact** ([SD boot](02-sd-boot.md)) |
| 2026-08-20 | ROCKNIX card re-flashed, `uboot` partition re-added → **ROCKNIX boots to UI** |
| 2026-08-20 | Card bring-up 1 — empty rootfs, `console=tty0` → unobservable; kernel has no framebuffer console |
| 2026-08-20 | Card bring-up 2 — stale boot image `id` found and fixed; U-Boot had been refusing the image after drawing our logo |
| 2026-08-20 | Card bring-up 3 — `rw` + `/BOOT-STAGE` markers; still nothing, cause still ambiguous |
| 2026-08-20 | Card bring-up 4 — kernel-side LED heartbeat proves the kernel runs; superblock shows `Last mounted on: /`, so root mounts |
| 2026-08-20 | Card bring-up 5 — `init=/init` added → **card boots to userspace. Chain complete.** |
| 2026-08-20 | Prepared inputs derived from the NAND backup; harvest list read from `/proc/<pid>/maps` on the running stock stack; closure verified |
| 2026-08-20 | Real rootfs built. Boot hangs with **no backlight** — pristine boot image's 943 KB resource; 465 KB boots. Isolated by swapping only the boot image |
| 2026-08-20 | adb failed: `cannot bind 'tcp:5037'`. Root cause **no loopback interface**; `adbd` treats the bind failure as fatal and never reaches `usb_ffs_init` |
| 2026-08-20 | **BaseOS boots with working adb.** `rcS` 50 ms, vendor binaries execute |
| 2026-08-20 | Resource image is now *built* rather than patched in place; pristine stock inputs restored |
| 2026-08-20 | fbsplash ported from `src/fbsplash.c`; `INSERT SD CARD` / `ADD FRONTEND TO SD CARD` restored |
| 2026-08-20 | Boot logo switched to the project artwork, backdrop subtracted to true black |
| 2026-08-20 | adb hot-plug confirmed working — no cable needed before power-on, unlike H700 |
| 2026-08-20 | Clean boot measured with USB unplugged: pre-kernel **4.96 s**, `rcS` 60 ms |
| 2026-08-20 | **Kernel stored gzipped: pre-kernel 4.96 s → 3.14 s.** Hand-off ≈4.8 s vs stock 15.8 s |
| 2026-08-20 | LZ4-legacy kernel tried → **does not boot**; reverted to gzip |
| 2026-08-21 | U-Boot disassembled: it **does** sniff for LZ4, but only frame framing with independent blocks. **LZ4 boots — and is 0.17 s slower than gzip.** gzip stays; no zstd in this U-Boot |
| 2026-08-20 | **NextUI launched from BaseOS** |

## SD boot investigation — result: **the stock SPL cannot boot from SD**

Two hardware experiments, then static analysis of the SPL binary.

### Experiment 1 — ROCKNIX card, right slot

`ROCKNIX-RK3566.aarch64-20260710-Specific.img.gz` written to a card, `extlinux.conf`
repointed to `rk3566-miyoo-flip.dtb`, `quiet` removed so the kernel log would render on
the panel via `console=tty0`. Card alone, right slot.

**Result: booted stock from NAND.** Kernel entry at 4.293 s.

The card's layout is correct for Rockchip's convention — `RKNS` IDB at sector 64,
`u-boot.itb` at **sector 16384 (`0x4000`)**, partition 1 starting at LBA 32768. The FIT
is structurally equivalent to the stock one:

| | stock `mtd1` FIT | ROCKNIX `u-boot.itb` |
|---|---|---|
| external-data FIT | yes | yes |
| `firmware` | `atf-1` | `atf-1` |
| `loadables` | `uboot, atf-2..6, optee` | `u-boot, atf-2..6` |
| `fdt` | `fdt` (rk3568-evb) | `fdt-1` (rk3566-quartz64-a) |
| sha256 hash nodes | yes | yes |
| ATF SRAM loads | `0xfdcc1000 / ce000 / d0000` | identical |

### Experiment 2 — add a GPT partition named `uboot`

Hypothesis: Rockchip's SPL locates U-Boot on MMC by GPT partition **name**, and
ROCKNIX's card has only `system` and `storage`. A partition named `uboot` was added
spanning LBA 16384–24575 — a partition-table edit only, no payload moved.

Verified on the card afterwards: entry 3 `name='uboot'`, LBA 16384..24575, and
`d00dfeed` present at sector 16384.

**Result: booted stock from NAND again.** Kernel entry at 4.259 s.

### Static analysis — what the SPL actually does

Disassembly of `mtd5` (capstone; ADRP targets are computable without knowing the load
address because the image is page-aligned in the file, so
`target_fileoff = (site & ~0xFFF) + imm*4096 + imm12`).

`spl_mmc_load_image` at `0x31558`:

```
0x3157c  bl 0x314b8          spl_mmc_find_device(&mmc, boot_device)
                               boot_device 1     -> mmc index 0  (sdhci)
                               boot_device 2 | 3 -> mmc index 1  (dwmmc@fe2b0000)
                               else -> "spl: unsupported mmc boot device."
0x3158c  bl 0x45a4c          mmc_init(mmc)   -> "spl: mmc init failed with error: %d"
0x315c0  bl 0x2e758          spl_boot_mode()
0x2e758:   mov w0, #1 ; ret      <-- ALWAYS MMCSD_MODE_RAW
0x3160c  bl 0x38d64          part_get_info_by_name(desc, "uboot", &info)
0x31610  tbz w0,#31 -> 0x31694   found    -> load FIT from info.start
0x31614                          not found-> print "spl: partition error"
0x31620  mov x2, #0x4000     ... and load FIT from RAW SECTOR 0x4000 anyway
```

Two consequences:

1. **`spl_boot_mode()` is unconditionally `MMCSD_MODE_RAW`.** The FS and EMMCBOOT paths
   are unreachable.
2. **Both the named-partition path and the failure path converge on sector `0x4000`.**
   The raw-sector fallback existed all along, so experiment 2's hypothesis was not just
   wrong — it could not have been the blocker. Experiment 1 should already have worked.

Therefore the failure is **upstream**, in `spl_mmc_find_device()` or `mmc_init()`.

### Why: the SPL has no way to power the slot

The Flip's SD rail is switched. From the stock kernel DTS:

```dts
dwmmc@fe2b0000 { vmmc-supply = <&vcc_sd>; vqmmc-supply = <&vccio_sd>; ... };
vcc-sd  { compatible = "regulator-fixed"; regulator-name = "vcc_sd";
          enable-gpio = <&gpio0 5 GPIO_ACTIVE_LOW>; enable-active-low;
          regulator-boot-on; min = max = 3300000; };
LDO_REG5 { regulator-name = "vccio_sd"; 1800000..3300000; always-on; boot-on; };
```

The stock SPL's device tree is a **generic Rockchip RK3568 EVB tree**. Its
`dwmmc@fe2b0000` node has **no `vmmc-supply`, no `vqmmc-supply`, no `bus-width`, no
`cap-sd-highspeed`**, and there is no io-domain setup (stock U-Boot proper does that
later — `io-domain: OK`).

And this is not merely a device-tree omission — **the regulator driver is not in the
SPL binary at all**:

| string | in `mtd5` |
|---|---|
| `gpio-controller`, `u-boot,dm-spl` | present |
| `regulator-fixed` | **absent** |
| `regulator-name`, `regulator-boot-on`, `regulator-min-microvolt` | **absent** |
| `vmmc-supply`, `vqmmc-supply` | **absent** |

So **patching the SPL's embedded DTB cannot work** — there is no `DM_REGULATOR` /
fixed-regulator code to consume the property.

Confirmation from the other side. ROCKNIX's own SPL (idbloader on the card, sector 458)
declares exactly what is missing, on the *same GPIO pins* as the Flip:

```dts
mmc@fe2b0000 { vmmc-supply  = <&regulator_vcc3v3_sd>;
               vqmmc-supply = <&vccio_sd>;
               cd-gpios = <&gpio0 4 GPIO_ACTIVE_LOW>;
               bus-width = <4>; cap-sd-highspeed; sd-uhs-sdr104; };
regulator-vcc3v3-sd { compatible = "regulator-fixed";
                      gpio = <&gpio0 5 GPIO_ACTIVE_LOW>;
                      regulator-name = "vcc3v3_sd"; regulator-boot-on; };
chosen { u-boot,spl-boot-order = "/mmc@fe2b0000", "/mmc@fe310000"; };
```

Quartz64-A and the Miyoo Flip share the SD power-enable GPIO (`gpio0` pin 5,
active-low) and card-detect (`gpio0` pin 4) — which is why a *generic* RK3566 ROCKNIX
U-Boot works on this device at all.

### What the SPL does and does not contain

Verified by locating each string and checking whether it falls inside the embedded DTB
(`0x685d8`/`0xc85d8`, 6058 bytes each) or in code/rodata — a compatible string in
code/rodata is a **driver match table**, i.e. the driver is compiled in.

| capability | evidence | present |
|---|---|---|
| dw_mmc (SD controller) | `rockchip,rk3288-dw-mshc` @ `0x5f0af` (rodata) | **yes** |
| sdhci (eMMC) | `snps,dwcmshc-sdhci` @ `0x5f18b` (rodata) | **yes** |
| SFC / SPI-NAND | `rockchip,sfc` @ `0x5fc1c`, `spi-nand` @ `0x5dca2` (rodata) | **yes** |
| DT props parsed | `bus-width`, `max-frequency`, `fifo-depth`, `non-removable` | yes |
| DT props **not** parsed | `cap-sd-highspeed`, `cd-gpios`, `broken-cd`, `disable-wp`, `sd-uhs-*` | — |
| regulator / `vmmc-supply` | `regulator-fixed`, `regulator-name`, `vmmc-supply` all absent | **no** |
| io-domain | `io-domain`, `rockchip,io-domain`, `vccio` absent | **no** |

The SFC result matters beyond diagnosis: a Rockchip 2017.09-vintage SPL **can** do
SPI-NAND boot, which is what the fall-back-to-stock leg of [investigation log](05-investigation-log.md) requires.

### Experiment 3 — stock's own FIT on the card (2026-08-20)

The strongest possible card-side test. Written to the test card:

- sector 16384 (`0x4000`), inside the GPT partition named `uboot`:
  **`mtd1-uboot.img` verbatim** — the device's own Rockchip-format FIT, *including*
  `os = "op-tee"`, i.e. the exact bytes this SPL loads successfully on every boot
- a GPT partition named `boot` at LBA 4292608 holding **`mtd2-boot.img` verbatim**

Both verified byte-exact on the card by slice-wise md5 before booting.

**Result: `storagemedia=mtd`. Booted from internal NAND.** Kernel entry 4.266 s; NAND
hashes unchanged. The kernel enumerated `mmcblk1p3` (4 MiB) and `mmcblk1p4` (38 MiB),
confirming the card was exactly as intended.

### Mechanism: card-side causes are exhausted

Three hypotheses have now been tested and refuted on hardware:

| # | hypothesis | refuted by |
|---|---|---|
| 1 | SPL locates U-Boot by GPT partition name `uboot` | Exp. 2 — added it, no change. Disassembly then showed a raw-sector `0x4000` fallback exists anyway |
| 2 | SPL cannot power the SD rail (no `vmmc-supply`/regulator) | GammaLoader's working SPL has no regulator support either |
| 3 | The SD chain must be Rockchip-format with OP-TEE | Exp. 3 — supplied the device's own OP-TEE-bearing FIT, no change |

The SPL was given *the exact bytes it loads every boot*, at *the exact sector its own
code falls back to*, inside *a partition with the exact name its own code looks up* —
and still did not take it. **The SPL does not successfully read the card at all.** The
failure is at MMC device/init level, before any FIT is examined, which is precisely
where the disassembly above localised it: `spl_mmc_find_device()` or `mmc_init()`.

**No card layout can fix this.** Every remaining variable is on the device side.

That GammaLoader exists at all is corroborating: it ships a *replacement* preloader
(SPL `2017.09-ga1f6fc00a0-210413`, Apr 2021, DDR `V1.10`) even though the stock boot
order already lists the SD first — which only makes sense if the stock SPL's SD path
does not work. The plausible reading is that Miyoo's later SPL builds broke or disabled
it.

**Caveat on adopting GammaLoader directly:** its bundled `boot.img.gz` is *not* this
unit's kernel (12 916 788-byte kernel and 944 128-byte resource, vs 36 647 424 and
465 408 in `mtd2` here). Installing it replaces the preloader **and** downgrades the
boot partition to a foreign kernel underneath a 2025-06-27 rootfs.

### Remaining ways to settle it

1. **UART on `ttyS2` @ 1 500 000.** One line of SPL output names the cause
   (`spl: could not find mmc device` / `spl: mmc init failed with error: %d` /
   `spl: unsupported mmc boot device.`). Earlier revisions of this file twice argued
   serial was not worth it "because the remedy is identical". That was wrong — the
   three messages imply different fixes, and card-side debugging has now been exhausted
   at a cost of three boots.
2. **Bypass the SPL entirely — [investigation log](05-investigation-log.md).** U-Boot proper does PMIC and io-domain init
   (`PMIC: RK8170`, `io-domain: OK`) that the SPL does not, and its own
   `rkimg_bootdev` prefers `mmc dev 1`. Testable without opening the case, and
   fail-safe.

### The left slot is unreachable regardless

`spl_mmc_find_device` maps `BOOT_DEVICE_MMC2` (2) **and** `BOOT_DEVICE_MMC2_2` (3) to
**mmc index 1**. Both `dwmmc` entries in the boot order therefore resolve to
`dwmmc@fe2b0000`. `dwmmc@fe2c0000` also has no `pinctrl` in the SPL DT. The left slot
cannot be an SPL boot source on this firmware.

---

## Stock U-Boot in `mtd1` — **proven to reach the SD card**

The SPL is a dead end ([investigation log](05-investigation-log.md)), but the next stage is not. Stock U-Boot already contains
`distro_bootcmd`, `bootcmd_mmc1`, `scan_dev_for_boot`, `scan_dev_for_extlinux` and
`sysboot`, and `boot_targets` already begins with `mmc1`. The only reason none of it
fires is ordering: the SPL passes a `bootdev` ATAG (`Bootdev(atags): mtd 1`), so
`boot_android mtd 1` runs first and succeeds, and the `run distro_bootcmd` at the tail
is never reached.

No environment backend is compiled in (`Loading Environment from`, `env_mmc`,
`env_nand`, `env_sf`, `env_fat`, `uEnv.txt` all absent), so the environment cannot be
overridden from a card. Changing it means patching `mtd1`.

### Experiment 4 — patched U-Boot flashed to `mtd1` (2026-08-20) — **SD boot works**

Applied to `mtd1`, all length-preserving in the compiled-in default environment plus
one flag in the control FDT, with the affected FIT `hash/value` nodes recomputed:

| | offset | change |
|---|---|---|
| `bootcmd` | `0xee48f` | `distro_bootcmd` moved to the front |
| `boot_targets` | `0xeecc7` | `mmc1 mmc0 mtd2 mtd1 mtd0 usb0 pxe dhcp` → `mmc1` |
| `cd-gpios` flags | `0x1f3bdc` | `0` (ACTIVE_HIGH) → `1` (ACTIVE_LOW), matching ROCKNIX for the same pin |

Written with `flash_erase /dev/mtd1 0 0 && nandwrite -p /dev/mtd1 …` from the running
stock system (`mtd1` has **0 bad blocks**, so `mtdblock` reads and `nandwrite` writes
are equivalent). Readback verified byte-exact.

**Result: ROCKNIX booted from the SD card.** Stock U-Boot located
`/extlinux/extlinux.conf` on the card, loaded `/KERNEL` with
`rk3566-miyoo-flip.dtb`, and started a mainline kernel.

**This is the load-bearing finding of the whole investigation.** The SPL cannot reach
the SD, but U-Boot proper can — it does the PMIC and io-domain init
(`PMIC: RK8170`, `io-domain: OK`) that the SPL never does. An SD-bootable BaseOS for
this device is therefore possible, at the cost of a `mtd1` patch.

### The bug in that first patch, and the fix

The patch was described as fail-safe. It was not. With **no card**, `mmc dev 1` fails,
`devtype` is untouched, and stock boots — correct. But with a card that has **no
`extlinux.conf`** (e.g. a NextUI card):

```
mmc_boot = if mmc dev ${devnum}; then setenv devtype mmc; run scan_dev_for_boot_part; fi
                                      ^^^^^^^^^^^^^^^^^^ clobbers devtype
```

`mmc dev 1` succeeds, `devtype` becomes `mmc`, the scan finds nothing, and the trailing
fallback `boot_android ${devtype} ${devnum}` has silently become `boot_android mmc 1`.
It looks for a `boot` partition on the *card*, finds none, and **hangs**. Observed on
hardware: no card → stock boots; NextUI card → stuck on the boot screen.

`mtd1` was restored from backup (verified `eaadbe9d…`) and NextUI recovered.

**Fix — hardcode the fallback target so it cannot be clobbered:**

```
bootcmd=run distro_bootcmd;boot_android mtd 1;boot_fit;bootrkp;
```

55 characters against the original 70, so it still patches in place with trailing
padding. `mtd 1` is exactly what the ATAG supplies today.

Built as `mtd1-uboot-sdfirst-v2.img` from the pristine original,
**md5 `ba5b8207b523a1a3de84fde4c9e0720b`**, 157 bytes changed, all 9 FIT hashes verify.
**Not yet flashed.**

### Experiment 5 — corrected `bootcmd` (v2) — fallback still hangs

`mtd1-uboot-sdfirst-v2.img` (md5 `ba5b8207b523a1a3de84fde4c9e0720b`, built from the
pristine original, 157 bytes changed, 9/9 FIT hashes verify), with

```
bootcmd=run distro_bootcmd;boot_android mtd 1;boot_fit;bootrkp;
```

Flashed and verified byte-exact; all other partitions unchanged.

| card | result |
|---|---|
| none | stock boots normally, wall-clock essentially unchanged |
| ROCKNIX (GPT, 2 GB FAT) | boots from SD, then stalls (see [port plan](04-port-plan.md)) |
| NextUI (MBR, **115 GB FAT32**) | **hangs indefinitely** — 2 minutes, no change |

So the `devtype` clobbering was *not* the cause: v2 fixes it and the symptom is
unchanged. The hang is specific to *a card being present that carries no
`extlinux.conf`*, and it is a genuine hang rather than slowness.

> **Retracted:** an earlier reading of this experiment claimed a ~20 s pre-kernel
> regression, from `dmesg` reporting kernel entry at 24.29 s against a 4.26 s baseline.
> Stopwatch measurement to the stock UI showed no such change. The kernel timestamp is
> not trustworthy across a warm reboot (the arch counter is not reset), and the
> wall-clock observation supersedes it.

**Unexplained.** One untested observation: the two cards differ in partition scheme
(GPT vs MBR) and by two orders of magnitude in volume size (2 GB vs 115 GB). U-Boot
2017.09's FAT/partition handling on a 115 GB FAT32 volume is a candidate, but this is a
hypothesis and has not been tested.

`mtd1` was restored from backup; all six partitions re-verified against the manifest.

### What actually triggers an SD boot

Not a partition named `boot` — that is `boot_android`, a different mechanism. The
distro path is:

```
scan_dev_for_boot_part : bootable partition (else partition 1), filesystem U-Boot knows
scan_dev_for_boot      : /extlinux/extlinux.conf | /boot/extlinux/extlinux.conf
                         | boot.scr.uimg | boot.scr
```

So a BaseOS card needs a **FAT partition carrying `extlinux/extlinux.conf`, a kernel
and a DTB** — considerably simpler than building Android boot images.

### Recovery

`back_to_bootrom` is present in the SPL alongside
`SPL: failed to boot from all boot devices`; a bad `mtd1` should return control to the
bootrom for USB MASKROM without opening the case. Untested. Beneath that sit `xrock`
and the verified `mtd1-uboot.img` backup ([backup & recovery](03-nand-backup-and-recovery.md)). In practice the revert was done entirely
over adb from the running stock system.

### Delivery: the vendor's own card-flash path

`runmiyoo-original.sh` looks for `miyoo355_fw.img` on either card, compares a
model/version header against `/usr/miyoo/version` (`20250627233124`), and runs
`/usr/miyoo/apps/fw_update/miyoo_fw_update`, which does:

```sh
dd if=miyoo355_fw.img of=/tmp/miyoo_fw_version.txt bs=128 count=1
dd if=miyoo355_fw.img of=/tmp/miyoo_update.sh     bs=512 skip=1 count=8
```

— the update script is embedded at sector 1 and **executed as root**, so the image
author controls exactly which partitions are written. Card image layout:
`uboot` @ `0x100000`, `boot` @ `0x800000`, `rootfs` @ `0x5000000`; the preloader is not
part of a card image. This is how NextUI already modifies stock, and is a safer
delivery vehicle than hand-rolled `nandwrite` for anything distributed to users.

### Fallback: replace the preloader

Only if the U-Boot route proves insufficient. Strictly worse: a built SPL, the Rockchip
`bootdev` ATAG to emit, a DDR blob that may mismatch stock BL31 and disable DMC, and a
first-stage mistake is the one failure with a real chance of needing disassembly.

**GammaLoader is not a drop-in** for this unit: alongside a replacement preloader it
flashes a `boot.img` whose kernel is 12 916 788 bytes with a 944 128-byte resource,
versus 36 647 424 / 465 408 in this unit's `mtd2` — i.e. it downgrades the kernel
underneath a 2025-06-27 rootfs.

## Retracted conclusions

Recorded because each cost a hardware experiment, and because the pattern matters:
each was a plausible mechanism asserted before it was tested.

| claim | why it was wrong |
|---|---|
| The ROCKNIX artifact was the "generic" build, not device-specific | ROCKNIX ships one image per SoC family; per-device selection is the extlinux `FDT` line. The quartz64-a U-Boot DTB is expected. |
| The *stock* SPL locates U-Boot only by GPT partition name | Disassembly showed a raw-sector `0x4000` fallback. (True of GammaLoader's SPL — [SD boot](02-sd-boot.md) — which is why the tip works there.) |
| The SPL cannot power the SD rail | GammaLoader's working SPL has no regulator support either. |
| The SD chain must carry OP-TEE | Exp. 3 supplied an OP-TEE-bearing FIT with no change; Exp. 6 boots a ROCKNIX FIT that has none. |
| The v1 `bootcmd` patch was "fail-safe by construction" | `mmc_boot` clobbers `devtype`; a card with no bootable content hung the device. |
| v2 added a ~20 s pre-kernel regression | Kernel timestamps are unreliable across warm reboots; stopwatch showed no change. |
| GammaLoader's preloader costs ~2.9 s of boot time | That sample had a non-bootable card inserted. With no card it is 4.31 s — within noise of stock. |
| A pulsing/steady `work` LED distinguishes success from failure | Its default trigger is `default-on`; a steady LED is the resting state. Only a *change* is signal. |
| `console=tty0` would show kernel messages on the panel | `# CONFIG_FRAMEBUFFER_CONSOLE is not set` — it renders nothing. The H700 doc records the same for its kernel, and it had already been read. |
| The empty-rootfs smoke test would prove the boot chain | It could not: with no console, "kernel panicked at init" and "kernel never started" look identical. Two rounds were spent on tests that could not distinguish success from failure. |
| The `work` LED steady meant the kernel was dead | Its default trigger is `default-on`. Twice read as a failure signal when it carried no information. |
| "No boot logo" meant U-Boot did not run | The logo had rendered near-blank — the vendor BMP is top-down and a negative height fed the scale calculation. The instrument was broken, so the reading was void, not negative. |
| Pre-kernel time had regressed to 7–8 s | USB was attached, so U-Boot ran its charge animation first and that landed in the arch counter. Measure with USB unplugged. |
| The rootfs "is not working perfectly well" | It was working: `rcS` ran to completion and wrote persistent state. Only the USB gadget had failed. |
| This U-Boot does not sniff for LZ4 on the Android path | It does — `lz4_valid_frame` is called straight out of `android_image_get_comp`. The evidence was a byte-grep for the magic as a literal, but arm64 splits a 32-bit constant across `movz`/`movk` bitfields, so the grep could not have found the check either way. The failing card was **legacy**-framed, the one format the sniffer ignores. |
| LZ4 would beat gzip because it inflates faster | Measured: 3.31 s against gzip's 3.14 s. It is 2.53 MiB larger, and the extra card read outweighs the faster inflate. |
| The measured gzip saving implied a ~13 MB/s read with free decompression | That was the degenerate root of `23.6/R − D = 1.82`. At a realistic 8–10 MB/s the inflate costs 0.5–1.1 s — which is what made LZ4 worth measuring in the first place. |
| The ROCKNIX stall was *not* the storage-partition collision | It was. The theory was abandoned when removing the blocking partition didn't help — but ROCKNIX's resize runs **once**, so the damage persisted. Correct diagnosis, wrong inference from the retest. |

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md)
