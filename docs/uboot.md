# U-Boot

**Part 1**: tuning the vendor U-Boot — tried, measured at 22 ms, code removed.
**Part 2**: replacing it — evaluated 2026-08-22 and shelved. **Part 3**: replacing
it after all — a first build booted on 2026-09-05, and this one is rebuilt from
what that taught, and the default since 2026-09-19; `MY355_UBOOT=vendor` builds
the vendor path. The decision is in [decisions](decisions.md); what each is worth is in
[boot time](boot-time.md).

---

# Part 1 — Tuning the vendor U-Boot: tried, 22 ms, abandoned

The binary contains `rockchip_read_resource_dtb`: this build has
`USING_KERNEL_DTB`, so after early init it **swaps its control device tree for our
`rk-kernel.dtb`**. Properties there steer the bootloader, not only the kernel. The
environment is not a second surface — `bootdelay=0` already, `bootcmd` short-circuits
on `boot_android`, and there is no environment storage driver in the binary.

Three knobs were implemented and measured on 2026-08-22, then **removed**:

| tried | result |
|---|---|
| delete `sd-uhs-sdr12`/`sdr25` from `dwmmc@fe2b0000` | no effect |
| `rockchip,uboot-charge-on` → 0, and drop the 171 KB of battery artwork it makes dead | ~22 ms, costs the low-battery boot guard |
| enable `crypto@fe380000` (the binary contains `Can't find crypto device for SHA1`) | **no effect** — tried 2026-09-16, see below |

Pre-kernel went 3.14 s → **3.118 s**. Not worth carrying.

The SD result is the useful one. The theory was that U-Boot attempts UHS, fails the
1.8 V switch and falls back to legacy 25 MHz — which is where the measured
10.9 MB/s sits, against the kernel's ~25 MB/s. The edit provably reached U-Boot's
tree (the kernel's own mode changed from `sd uhs SDR25` to `new high speed SDXC
card`, both 50 MHz) and the budget did not move. **So the slow read is not a UHS
fallback**; the cause is inside the binary — transfer sizes, no DMA, or the SHA1 —
and unreachable from a device tree. Halving that 1.19 s needs Part 2.

Mainline had the same ceiling for a reason now found: on this SoC the SD
controller halves its input clock, and mainline's RK3568 clock driver did not
provide for it, so "50 MHz" ran the card at 25 MHz (Part 3, *The SD clock*).
10.9 MB/s sits under that 12.5 MB/s cap too, so the vendor binary most likely
carries the same driver; its source was not checked.

**The crypto block, 2026-09-16.** The vendor U-Boot has a
`rockchip,rk3568-crypto` driver, and the node ships `disabled`, so the SHA1 over
the boot image was assumed to run in software. With `status = "okay"`, two cold
boots put the first printk at 2.858 s and 2.856 s, against 2.856 s without it.
**No measurable gain.** Either the software hash was already cheap, or this path
never uses the device; without a console, the two cannot be told apart. The
kernel side was harmless: `rk-crypto` bound, its algorithms registered at
priority 0 below the CPU's own (250–300), and the kernel phase did not move. It
added one `rk-crypto fe380000.crypto: invalid resource` line. Reverted.

Two things were found along the way and kept.

**The `.hdmi` device tree — a bug, now fixed.** The resource image holds
`rk-kernel.dtb` *and* `rk-kernel.dtb.hdmi`; U-Boot selects the second when Miyoo's
`g_miyoo_use_hdmi` is set. Only the first was ever patched, so the variant still
carried the stock `root=/dev/mtdblock3 rootfstype=squashfs` — **BaseOS would not
have booted on that path.** `setargs` now patches every `rk-kernel.dtb*` entry and
asserts `root=` on each.

**The panel is the floor of U-Boot's display work, and it is a choice.**
`dsi@fe060000/panel@0`'s `panel-init-sequence` holds **282 ms of mandated sleep**
(DCS `exit_sleep_mode` 250 ms, `set_display_on` 32 ms) — 23% of U-Boot's 1.21 s
initialisation, and the price of the logo appearing at ~1.0 s. Deleting `logo,uboot`
from `route-dsi0` skips display bring-up entirely, worth ~0.3–0.45 s, at the cost of
a dark screen until the kernel splash at ~2.9 s. Not taken.

Also noted and deliberately left alone: `route-hdmi` is `okay`, so U-Boot probes
HDMI every boot and gets nothing (on a live unit it patched `logo,offset` into
route-dsi0 only, and `card0-HDMI-A-1` reads `disconnected`). Worth 0.05–0.2 s, but
HDMI is supported on stock and NextUI.

# Part 2 — Replacing it (evaluated 2026-08-22, superseded by Part 3)

> Kept as the record of what was believed before anything was booted. Its
> 1.2–1.7 s estimate and its zstd case are **refuted** by measurement; see Part 3.

The card's `uboot` partition holds the vendor 2017.09 FIT verbatim. Replacing it
with a lean mainline build was evaluated and **shelved**.

## What it would buy

Of the 3.14 s pre-kernel budget, **1.21 s is the vendor U-Boot initialising before
it fetches a byte** — AVB/trusty probing, GPT repair, charge-animation, a full DRM
bring-up, a SHA1 over the whole boot image.

It is also what makes zstd reachable: the Android boot image path *sniffs* the
payload (zImage → LZ4 → gzip → LZMA → none) and there is no zstd case to add. A FIT
declares `compression` per image.

Estimated total: **1.2–1.7 s**, taking power-on → NextUI input from 7.6 s to ~6.0 s.

## The risk is low, and it is not where it looks

The `uboot` partition is **on the card**. The SPL resolves it by name; if
the FIT is missing or broken the SPL walks its boot order down to
`/sfc@fe300000/flash@0` and boots stock from NAND — the behaviour already verified
as Experiment 6's "NextUI card, no `uboot` partition" case. No NAND write is
involved. The failure mode is "this card does not boot", and reverting is a `dd` of
8 MiB.

That is a different proposition from patching `mtd1`, which holds BL31 and OP-TEE
and hung twice (Experiments 4 and 5). Do not confuse the two U-Boots. Note BL31
already comes from the card on this path, so a replacement changes the running ATF
too — equally card-side, equally reversible.

## The stock DTB works as U-Boot's control tree

Mainline U-Boot binds against every compatible on the boot path, because the stock
DTB carries mainline-compatible fallbacks:

| stock DTB | mainline U-Boot driver |
|---|---|
| `rockchip,rk3568-dw-mshc`, **`rockchip,rk3288-dw-mshc`** | `rockchip_dw_mmc.c` |
| `rockchip,rk3568-pinctrl` | `pinctrl-rk3568.c` |
| `rockchip,rk3568-cru` | `clk_rk3568.c` |
| `rockchip,rk817` | `rk8xx.c` |
| `regulator-fixed` | `fixed.c` |
| `rockchip,rk3399-i2c` | `rk_i2c.c` |
| `rockchip,gpio-bank` | `rk_gpio.c` |
| `rockchip,rk3568-pwm`, **`rockchip,rk3328-pwm`** | `rk_pwm.c` |

**No reverse engineering is needed for the boot path**, and no third-party DTS.

## The blocker: no VOP2 driver in U-Boot

**Mainline U-Boot v2026.07 has no display driver for this SoC.**
`drivers/video/rockchip/` stops at rk3399 — `rk3288_vop.c`, `rk3328_vop.c`,
`rk3399_vop.c` — and `vop2` appears nowhere in `drivers/`. The rk3566 handheld
defconfigs (`anbernic-rgxx3`, `powkiddy-x55`) enable `VIDEO_ROCKCHIP` and the DSI
PHY, but there is no display controller under them.

This device has no console, so a U-Boot that draws nothing leaves the panel dark
until something else lights it. A seamless boot logo therefore means **writing a
VOP2 driver**, not porting a panel node.

> **Retracted.** An earlier reading held that the splash was a matter of porting
> ROCKNIX's panel node and borrowing the rgxx3 video config. There is no
> controller for those to sit on.

### The cheaper variant, and why it is still RE

The vendor kernel draws `logo_kernel.bmp` itself: `/display-subsystem/route/*`
carries `logo,uboot` and `logo,kernel`, and the kernel reads a `drm-logo` reserved
region. Evidence it is U-Boot that populates it — `dmesg` on a normal boot:

```
rockchip-drm display-subsystem: route-hdmi: failed to get logo,offset
```

`logo,offset`/`logo,size` are patched into the DTB by U-Boot; the kernel, which has
full VOP2 support, does the drawing. A display-less U-Boot could in principle just
place the BMP and set two properties. But that contract has to be recovered from a
BSP kernel with no published source, on a device with no console.

> **Retracted (2026-09-19).** It is not a cheaper variant. The hand-off tells
> the kernel the display is already running, and Rockchip's 5.10 display
> drivers then skip bringing the panel up, so a logo staged by a U-Boot that
> never lit the panel would stay dark. That is from Rockchip's public source,
> not tested here. The contract itself is not RE either: the vendor U-Boot is
> Rockchip's `next-dev` display stack, published (Part 3, *The boot logo*).

## The zero-RE option, if this is revisited

> Done on 2026-09-19, and it took more than drawing: the panel came up at
> 2.99 s, the backlight stayed off and NextUI erased the logo first (Part 3,
> *The boot logo*). The logo now shows from 2.43 s.

Lean U-Boot + stock DTB + **no video at all**, drawing the splash from the kernel
side with the `baseos-splash` fbsplash the rootfs already ships. Cost is cosmetic
and bounded: the logo appears at ~2.9 s instead of ~1.0 s while the whole boot drops
to ~6.0 s.

The real cost is **blind iteration**: no console without opening the case, so a
U-Boot that dies early is indistinguishable from one that never started. Mitigable
by toggling the `work` LED at known stages, as
[bring-up](diagnostics.md) does for the kernel.

## Findings worth keeping

From the build that was made and then removed (U-Boot v2026.07,
`quartz64-a-rk3566_defconfig`, rkbin `rk3568_bl31_v1.46.elf`):

- The vendor FIT's structure, read out of `work/my355/prepared/uboot.img`:

  | image | size | load |
  |---|---|---|
  | `uboot` | 1 321 040 | 0x00a00000 |
  | `atf-1` (firmware) | 167 936 | 0x00040000 |
  | `atf-2`…`atf-6` | 40 960 / 20 291 / 8 192 / 8 192 / 7 888 | SRAM + 0x69000, 0x6b000 |
  | `optee` | 461 216 | 0x08400000 |
  | `fdt` ("U-Boot dtb") | 14 360 | — |

  `configurations/conf` is `rk3568-evb`, `firmware = "atf-1"`,
  `loadables = "uboot atf-2 atf-3 atf-4 atf-5 atf-6 optee"`. Every image carries a
  `sha256` hash and the config an `algo = "sha256,rsa2048"` signature.
- **There is a second control device tree.** The FIT's own 14 KB `fdt` governs
  early init, before the swap to `rk-kernel.dtb` — and its `dwmmc@fe2b0000` has
  `u-boot,dm-spl`, `cd-gpios` and **no speed capabilities at all**. It is on the
  card, so it is patchable and reverts with `dd`; the sha256 hashes are
  recomputable, the RSA signature is not. If the SPL rejects it, it falls through
  to NAND, so the experiment fails safe. Untried.
- Our own FIT was structurally what the SPL already loads: external-data,
  `firmware = atf-1 @ 0x40000`, identical ATF SRAM load addresses, 1 003 008 bytes
  into an 8 MiB partition. OP-TEE absent — not required, per Experiments 3 and 6.
- **`u-boot.itb` is not a make target** on Rockchip; binman emits it inside
  `simple-bin` during the default build (`arch/arm/dts/rockchip-u-boot.dtsi`).
- `simple-bin` and `simple-bin-spi` both demand the proprietary Rockchip DDR blob
  for `idbloader.img`. Both are first-stage concerns and our first stage is the
  preloader in NAND: turn off `ROCKCHIP_SPI_IMAGE` and pass
  `BINMAN_ALLOW_MISSING=1`. `u-boot.itb` is a separate binman member.
- `rk356x-u-boot.dtsi` overrides the board aliases to `mmc0 = sdhci` (eMMC, absent)
  and `mmc1 = sdmmc0`, which matches the vendor kernel's numbering.
- The default `CONFIG_BOOTCOMMAND` is `bootflow scan -lb`, which enumerates every
  bootdev against every bootmeth — the work this exercise exists to delete. It also
  cannot read the card as it stands: the `boot` partition is a Rockchip Android boot
  image whose DTB lives in an `RSCE` resource image.
- Intended payload, if revisited: a **raw FIT at a fixed sector**, no filesystem and
  no scan — `mmc dev 1 ; mmc read ${addr} ${sector} ${count} ; bootm ${addr}` — with
  the vendor `Image` at `compression = "zstd"` and the patched vendor DTB. Since
  `mmc read` needs a length, put the sector count as a little-endian `u32` in a
  512-byte header sector and read twice, so the kernel can change size without
  rebuilding U-Boot.
- rkbin BL31 v1.46 against the DDR blob in `mtd5` is unverified. The check is
  `rockchip-dmc` in dmesg — all four FSPs, no `loader&trust unmatch!!!` — as
  [SD boot](boot-chain.md) did for the preloader swap. Stock's own BL31 is TF-A v2.3
  (Jun 2023), so an older rkbin BL31 is the fallback.

# Part 3 — Mainline U-Boot, the default (2026-09-19)

`./build-all.sh` builds it, or `./build-uboot.sh` then `./build-image.sh`;
`MY355_UBOOT=vendor` puts the vendor U-Boot back. It **boots**, and it reaches `Run /init` **1.47 s earlier** than the vendor path:
2.09–2.12 s against 3.58 s, with NextUI starting at 2.69–2.73 s against
4.19–4.23 s (2026-09-19, four cold boots; U-Boot's own timings agree to 0.1 ms).
Everything below is measured on this unit and card unless marked otherwise.

## What the first build measured (2026-08-24 / 09-05)

Flashed 2026-08-24: dark screen, no kernel. The kernel was never told OP-TEE
sits resident at `0x08400000`, overwrote it and died after `Starting kernel`.
The vendor U-Boot hides those 16 MiB by splitting `/memory` (the stock serial
log: `Adding bank 0x00200000 - 0x08400000`, then `0x09400000 - …`); mainline
does not. Fixed with a `/reserved-memory` node, confirmed on the next boot by
the kernel reserving exactly 16 MiB more.

Booted 2026-09-05, one U-Boot binary, one cold boot per payload:

| payload | FIT | first printk | kernel → `Run /init` | → `rcS` done |
|---|---|---|---|---|
| vendor U-Boot, gzip | 13.09 MB | 3.134 s | 1.523 s | **4.83 s** |
| mainline, gzip | 13.09 MB | **2.682 s** | 2.095 s | 4.99 s |
| mainline, none | 36.75 MB | 4.188 s | 2.098 s | 6.50 s |
| mainline, zstd | 10.93 MB | 4.277 s | 2.107 s | 6.61 s |

0.45 s faster before the kernel, 0.57 s slower inside it. **Retracted:** "zstd
decodes in ~2.1 s against gzip's ~0.35 s, and it stays out". The 0.35 s was the
vendor U-Boot's inflate, borrowed; mainline's is 0.61 s at the same clock, and
zstd's slowness was U-Boot's build flags, not zstd (below).

## What was re-examined, and what changed

| belief from the first build | now | evidence |
|---|---|---|
| The vendor U-Boot hands the kernel a CPU at 1104 MHz; mainline at 816 | **verified, fixed** | stock serial log: `CLK: (sync kernel. arm: enter 816000 KHz …)`, `armclk 1104000 KHz`; mainline `cru_rk3568.h`: `APLL_HZ (816 * MHz)`. Before cpufreq, the kernel took 0.788 s at 816 MHz against the 0.785 s the ratio predicts |
| `vdd_cpu` is a TCS4525 at i2c0 `0x1c`, at 850 mV | **wrong** | the Flip has an **RK8600 at `0x40`** (i2cdump of `0x1c` is empty; Miyoo confirmed one SKU, per the wiki). It powers on at **1000 mV** (VSEL0 `0x97`, read by our U-Boot). The 850 mV was read from a running kernel after cpufreq had set it |
| quartz64-a's control tree is correct for the Flip | **SD slot only** | right for `sdmmc0`'s rails and card detect, wrong for the CPU rail, and it describes Ethernet, PCIe and USB this board lacks |
| its size is what makes early init slow (287 ms of driver model before relocation), so a Flip tree is the fix | **wrong** | the cost was reading any tree with the data cache off: cached, the same binding takes 9 ms (below). A Flip tree remains worth having for correctness, not speed |
| early init is slow because instructions are fetched uncached | **wrong** | enabling the I-cache first thing in `board_init_f` moved no step by more than 0.5 ms: the SPL leaves it on |
| U-Boot may read the kernel at a fixed sector | **wrong** | an A/B update moves `boot` to its other half (`src/gptslot.c`: nothing in the boot chain references an address). That U-Boot would have booted the old kernel on the new rootfs |
| U-Boot init ~0.91 s, SD read ~12.7 MB/s | **measured: 0.97 s, 12.0 MB/s** | bootstage, below. The inferred split had borrowed the vendor's inflate time |
| zstd is slower than gzip on this SoC | **wrong** | U-Boot builds arm64 with `-mstrict-align`, and `ZSTD_LIB_MINIFY` defaults on; together 5.6x. Below |
| SDR50 in U-Boot needs only `mmc_of_parse()` and two Kconfig lines | **incomplete** | U-Boot's io-domain driver sets `PMU_GRF_IO_VSEL` once, at probe; the 1.8 V switch never updates it. Not attempted |
| U-Boot drives the card at 50 MHz, and 12.0 MB/s is what that allows | **wrong: 25 MHz** | the controller halves its input clock and mainline's RK3568 clock driver did not provide for it (below). Fixed: **23.8 MB/s** |

**Zlyme** and **ROCKNIX** both boot this unit with mainline U-Boot v2026.01 on
`quartz64-a-rk3566_defconfig` plus charger-wake shutdown, an rkbin BL31 and an
extlinux scan of a FAT partition, into a mainline kernel. They prove the stock
SPL loads a mainline `u-boot.itb`; they are not built for speed (Zlyme: "under
10 seconds"). Their Flip device tree is the reference for the RK8600 and the LEDs.

## Where U-Boot's time goes

Bootstage, debug build, USB unplugged, each change added to the one before:
three cold boots at 816 MHz agreeing to 0.2 ms, one at 1104 MHz, one with the
zstd kernel, four with the SD clock fixed, then five with the early data cache,
each set agreeing to 0.1 ms. The fuel gauge step (`my355 fg`, below) came
between the last two.

| stage | 816 MHz, gzip | 1104 MHz | zstd | SD clock | **early cache** | |
|---|---|---|---|---|---|---|
| → `board_init_f` | 45 ms | 45 | 45 | 45 | 45 | |
| **pre-relocation init** | 568 ms | 566 | 569 | 570 | **40** | the data cache is off until `initr_caches()`; `dm_f` 287 → 9 ms (below) |
| post-relocation init → `main_loop` | 59 ms | 59 | 59 | 59 | 59 | |
| `my355 cpu 1104`, `my355 fg` | — | 2 | 2 | 2 | 16 | |
| **card init** (`mmc dev 1`) | 295 ms | 290 | 289 | 202 | 202 | the kernel initialises the same card, SDR104 tuning included, in 90–220 ms. Why the clock fix also took 87 ms off is not established |
| **read** (header + FIT) | 1,054 ms | 1,053 | 1,063 | 536 | 536 | 12.0 MB/s, then **23.8 MB/s**: 95% of 4-bit 50 MHz |
| debug log save | 8 ms | 8 | 8 | 7 | 7 | the debug build's whole cost |
| **decompress** | 608 ms | 447 | 347 | 348 | 347 | gzip, then zstd |
| FIT checks, FDT fixups, hand-off | 28 ms | 13 | 12 | 12 | 12 | |
| **`start_kernel`** | 2,664 ms | 2,492 | 2,405 | 1,791 | **1,274** | |

| | vendor (docs) | 816 MHz, gzip | 1104 MHz | zstd | SD clock | **early cache** |
|---|---|---|---|---|---|---|
| first printk | 2.85 s | 2.723 s | 2.537 | 2.450 | 1.837 | **1.320** |
| `Run /init` | 3.58 s | 3.654–3.670 s | 3.440 | 3.239 | 2.663 | **2.09–2.12** |
| `nextui.elf` start | 4.19–4.23 s | | | | 3.26–3.27 | **2.69–2.73** |
| first NextUI frame | — | | | | 4.09–4.10 | **3.53–3.57** |

The first frame is timed by polling the DRM state (`MY355_DIAG=1`, below),
because this path has no kernel marker for it. The vendor path's, `Freeing
drm_logo memory` at 5.72–5.75 s, is not the same event, so the two are not
compared.

The kernel phase, 0.77–0.83 s, varies with SD card detection (88–219 ms from
controller probe to `new ultra high speed SDR104`). One boot with the SD clock
fixed reached `Run /init` at 3.050 s: its root needed an ext4 journal replay
(`EXT4-fs (mmcblk1p3): recovery complete`) after an unclean shutdown, which
is the root being mounted `rw` ([decisions](decisions.md)), not U-Boot. One of
the five early-cache boots lost 0.42 s the same way, in the kernel, with U-Boot
unchanged; its log was gone before either cause could be checked, and
`baseos-bootinfo timeline` now reports both.

Bootstage and printk share the arch counter (hand-off at 1,274 ms, first printk
at 1,320 ms), but its zero is **not** power-on: `board_init_f` reads 45 ms,
after a bootrom, DDR init, SPL and BL31 the docs put at 0.39 s. Comparisons
between the two paths hold, because everything before U-Boot is identical on
both; "power-on-relative" elsewhere in these docs means "since the counter
started". Open.

## The CPU clock

`my355 cpu 1104` (patch `0001`) runs first in the boot script: it checks the
RK8600's ID, reads VSEL0 (712.5 mV + 12.5 mV per step, 6-bit, confirmed against
the kernel's own reading), raises it to 900 mV only if it is lower, then sets
`ARMCLK` and reads it back. On this unit the rail already sits at 1000 mV, so
it only sets the clock. **Nothing above 1104 MHz**: the vendor kernel sets
`vdd_cpu` to its `regulator-init-microvolt` of 900 mV when the regulator probes,
before cpufreq, so a faster hand-off would be under-volted for that window.

Inflate 608 → 447 ms, first printk 2.723 → 2.537 s. The kernel phase moved less
than predicted (0.94 → 0.90 s) because it now waits on the SD card: detection
took 212 ms on that boot against 90 ms on an earlier one.

## zstd

Measured by linking **U-Boot's own compiled decoders** — `lib/zstd`, `lib/zlib`,
`lib/xxhash`, `lib/string.c`, built with U-Boot's exact flags and renamed so
glibc's routines never stand in — into a static program run on the Flip at a
pinned 1104 MHz (`tools/uboot/decomp-bench/`). Its gzip reads 428 ms against the
447 ms U-Boot measured itself, so the numbers carry over.

| decoder build | 8 MiB window + checksum | 8 MiB | 1 MiB | 128 KiB | level 9 |
|---|---|---|---|---|---|
| U-Boot as built | 1,982 ms | 1,869 | 1,816 | 1,704 | 1,538 |
| without `MINIFY` | 1,793 | 1,667 | 1,564 | 1,390 | 1,334 |
| without `-mstrict-align` | 998 | 1,050 | 915 | 784 | 811 |
| **without either** | 738 | 630 | 503 | 446 | 650 |

* **`-mstrict-align`**, which U-Boot applies to all of arm64, turns zstd's
  unaligned loads and 16-byte copies into byte operations: 2x. gzip, which works
  bytewise anyway, gains only 428 → 392 ms.
* **`ZSTD_LIB_MINIFY`** strips the fast decode paths to save ~50 KB: a further
  1.6x once alignment is fixed, almost nothing before.
* **The window**: 8 MiB of history does not stay in this SoC's caches; 128–256
  KiB does, 1.4x.
* **The checksum** costs ~100 ms to verify.

Tuned on the fixed decoder, `--ultra -22 --zstd=wlog=18,mml=6 --no-check`
decodes in **352 ms** at 12.64 MB — slightly *larger* than gzip's 12.50 MB,
because a larger minimum match trades ratio for fewer, longer copies. At the
current read rate every good setting lands within 15 ms of it (the smallest,
11.28 MB, decodes in 467 ms); this one is chosen because it keeps winning if the
read gets faster:

| | size | decode | read at 12.0 MB/s | total |
|---|---|---|---|---|
| gzip, U-Boot as built | 12.50 MB | 428 ms | 1,042 ms | 1,470 ms |
| gzip, unaligned allowed | 12.50 MB | 392 ms | 1,042 ms | 1,434 ms |
| zstd, first build | 10.83 MB | 1,982 ms | 903 ms | 2,885 ms |
| **zstd, as shipped here** | 12.64 MB | **352 ms** | 1,053 ms | **1,405 ms** |

Predicted −65 ms against gzip; booted, it decoded in **347 ms** and moved
`start_kernel` by **−87 ms**. At the 23.8 MB/s the read runs at since, the
smallest setting would lose: 475 + 467 ms against 531 + 348 for this one.
Patch `0003` builds `lib/zstd`, `lib/zlib` and `lib/xxhash` with
`-mno-strict-align` and clears `SCTLR.A` in `image_decomp()`: bootm decompresses
after relocation, with the MMU on and DRAM mapped as normal memory, where that
bit is all that could forbid an unaligned access. `CONFIG_ZSTD_LIB_MINIFY` is
off. `mkfit.py` owns the encoder settings; `MY355_COMPRESS_KERNEL=gzip` still
builds a gzip FIT.

## The SD clock

On the RK3568 the dw_mmc controller divides its input clock by 2 before the
card sees it. The kernel provides for it (`RK3288_CLKGEN_DIV`): on this unit,
`clk_sdmmc0` runs at 297 MHz to drive the card at 148.5 MHz. U-Boot's
px30, rk3308, rk3328 and rk3399 clock drivers do the same, taking and
reporting the card's rate and programming the CRU at double. **The rk3568
driver maps the request straight onto the CRU**, so the MMC core's 50 MHz
reached the card as 25 MHz, and 4-bit 25 MHz caps a read at 12.5 MB/s: the
12.0 measured. The core never knew; `mmc info` printed `Bus Speed: 50000000`
throughout. Unfixed on upstream master as of 2026-09-18, and Zlyme and ROCKNIX
build this driver too.

Patch `0004` provides the double: 50 MHz → the 100 MHz source, 25 → 50, and
400 kHz stays on the 750 kHz source (375 kHz at the card, as before). The read
went **1,063 → 536 ms**, 23.8 MB/s. U-Boot programs no drive or sample phase;
what the SPL leaves (`SDMMC0_CON0/1` = `4`/`0`: drive 180°, sample 0°) is what
Linux uses at these speeds, and the debug build logs both registers alongside
`mmc info`.

The next doubling is SDR50: 100 MHz at 1.8 V, no tuning needed. It needs the
1.8 V switch, which U-Boot's io-domain driver does not follow (it sets
`PMU_GRF_IO_VSEL` once, at probe), and it hands the kernel a card already at
1.8 V. Not attempted.

## Early init: the data cache before relocation

U-Boot's own init took 570 ms before relocation and 59 ms after it. A build
with a bootstage mark after every initcall (`MY355_DIAG=1`, below) put nearly
all of it in two steps:

| step, before relocation | caches off | **data cache on** |
|---|---|---|
| `initf_dm` — bind driver model from the tree | 287.7 ms | **9.2** |
| `serial_init` — probe the UART, and with it the CRU and pinctrl | 221.9 ms | **0.0** (7.2 in `console_init_f`) |
| `print_resetinfo` | 21.8 ms | 0.7 |
| the relocation itself (billed to `initr_trace`) | 12.5 ms | 0.5 |
| everything else, ~60 steps | ~26 ms | ~23 |
| **`board_init_f` → `board_init_r`** | **570 ms** | **40** |

After relocation the same binding and probing (`initr_dm`) took 38 ms. The
first suspect, uncached instruction fetches, was wrong: enabling the I-cache
first thing in `board_init_f` moved nothing, so the SPL already leaves it on.
The cause is data: with the MMU off, every load is a Device access straight to
DRAM, and the flat device tree is read property by property, names compared
byte by byte.

Patch `0005` turns the MMU and data cache on in `arch_cpu_init()`, before
driver model, and changes nothing else:

- **The same memory map** as the rest of U-Boot: Rockchip's `rk3568_mem_map`,
  DRAM Normal and cacheable, peripherals Device. Everything after relocation,
  the card read and `bootm` included, already ran under it; now the 40 ms before
  does too.
- **The page tables** sit in a 64 KiB array in `.data` (`.bss` is not usable
  before relocation): 66 KB more FIT to read, ~3 ms. If U-Boot's own estimate
  of the tables it needs (`get_page_table_size()`) ever exceeds that, the early
  cache is skipped and the boot proceeds as before, because a panic this early
  would be invisible.
- **The two transitions** are covered by existing code: `relocate_code()`
  cleans the relocated copy when the data cache is on, and the patch's
  `enable_caches()` flushes, disables and rebuilds the tables in the area
  `arch_reserve_mmu()` reserved.
- **Nothing does DMA** that early: the card is first touched after relocation.
- **Precedent**: STM32MP1, STM32MP13x and STM32MP2 enable the data cache before
  relocation in U-Boot proper the same way (`arch/arm/mach-stm32mp/`), as do
  Layerscape and Versal.

Verified 2026-09-19: five cold boots, a warm reboot, a cold boot with the
charger attached; the charger-woken power-on (which should switch itself off
again) is untested. Worth **530 ms**, carried unchanged to the first frame. A
failure would look like the dark screen of the first diagnostics build: a hang
before the boot script, which the SPL does not catch because the FIT is valid,
recovered by re-flashing or from stock with the card in the left slot.

It is the best candidate to send upstream with `0004`, generalised to Rockchip
arm64. A Flip device tree stays worth doing for correctness (the RK8600, no
phantom Ethernet, PCIe or USB), no longer for speed.

## What the kernel relied on the vendor U-Boot for

The vendor U-Boot edits the kernel's world before hand-off, and the vendor
kernel depends on each edit without saying so. Mainline does none of them, so
this path does each one itself. Three are known; each was found by its failure.

| the vendor U-Boot | without it, on mainline | done here by |
|---|---|---|
| splits `/memory` around OP-TEE at `0x08400000` | the kernel allocates over resident secure firmware and dies after `Starting kernel` (2026-08-24) | `mkfit.py boot`: a `/reserved-memory` `no-map` node |
| writes `rockchip,plane-mask` and `rockchip,primary-plane` into each VOP2 port (`rk3568_assign_plane_mask`) | the kernel's default gives the panel's port (`vp1`) the RK3566's mirror windows, which scan out nothing: **NextUI runs, the panel is black with the backlight on**. dmesg: `current plane mask: 0x0 … use default plane mask` | `mkfit.py boot`: the vendor's policy — the non-hot-plug display gets the main windows |
| reconciles the RK817 fuel gauge and sets `FG_INIT` (`fg_rk817.c`) | the kernel reads charge gained while off as a halted session and restarts the displayed SOC from **0% on a full battery**; a low-battery shutdown would follow unplugged | `my355 fg`, in the boot script |

**The display planes.** On the RK3566, Cluster1, Esmart1 and Smart1 only mirror
their main window. The vendor U-Boot hands the main windows to the first
display that cannot be hot-plugged, "to ensure that the mirror planes are not
enabled first": the DSI panel gets `0x15` (Cluster0, Esmart0, Smart0; primary
Smart0), HDMI `0x2a` (the mirrors; primary Smart1). `rkbootimg.set_vop2_plane_masks`
writes exactly that, finding each encoder's VOP port from the tree's endpoints
rather than assuming it, and refuses a tree that already assigns planes. HDMI
while docked is untested on this path.

**The fuel gauge.** The RK817 keeps its state across power-off in PMIC
registers: a coulomb counter, and the SOC and capacity the kernel last saved.
Left alone, the kernel compares the two, and a gap over 10% of FCC — charging
while off gives one — it takes for a crash, restarting from an `rsoc` it has not
yet computed: 0. NextUI's battery log on this unit shows it happening, 78 → 54
→ 0 → creeping up 1% at a time on a battery at 4.19 V. `my355 fg` (patch
`0001`) does the vendor U-Boot's reconciliation: the counter's change since
the last save moves the SOC (both directions, where the vendor counts only
charge), SOC, capacity and counter are written back, the off-minutes counter
restarts and `FG_INIT` tells the kernel to take it (`rk817-bat: initialized
yet..`). One addition: a saved SOC more than 10 points from the counter's is
replaced by the counter's, which repaired this unit's corrupted 12% to 99.9% on
the first boot (2026-09-19). A battery reconnected from empty (`BAT_CON`), or a
counter the PMIC marks invalid, is left to the kernel's own voltage estimate.
The kernel's charger driver sets input and charge limits itself from its tree
(`rk817_charge_pre_init`), so nothing else of the vendor's `fg_rk817.c` is
needed. Like stock, this skips the kernel's recalibration from resting voltage
after 30 minutes off; doing it here needs the OCV table from the kernel's tree.
It costs 13.5 ms of I2C.

## The boot logo

Mainline U-Boot has no VOP2 driver, so it draws nothing and the kernel brings
the panel up itself. `rcS` then draws the BaseOS logo into `/dev/fb0`
(`fbsplash 0`, the artwork the vendor path's logo is cropped from) and lights
the backlight. It does neither when the tree carries `logo,offset`, which is
the vendor U-Boot handing its own logo over.

One cold boot, 2026-09-19:

| | mainline | vendor path |
|---|---|---|
| logo drawn (`rcS`) | 2.13 s | ~1.0 s, by U-Boot |
| backlight on | 2.27 s | with the logo |
| **logo on the panel** (`dw_mipi_dsi_bridge_enable`) | **2.43 s**, was 2.99 | ~1.0 s |
| NextUI sets its brightness | 2.96 s | |
| first NextUI frame | 3.56 s | 5.72–5.75 s |

So the logo is up for about 1.1 s, arriving 1.4 s after the vendor's. It took
three fixes, each found on the device with `baseos-frameprobe` (below):

- **The panel's waits.** The kernel switches the panel's supply on at 2.02 s,
  then waits `reset-delay-ms` 160, `init-delay-ms` 200, the init sequence's own
  250 + 32 and `enable-delay-ms` 200 before the DSI link streams a pixel. There
  is no reset line, so the first two only wait out power-on. The boot script
  now powers the panel first (`gpio set A23`, gpio0 PC7, `vcc3v3_lcd0_n`), and
  `rkbootimg.set_panel_delays` sets 160/200/200 to 0/20/0: the link streams at
  2.43 s against 2.99. The panel controller's 282 ms stay.
- **The backlight.** U-Boot never enables its PWM, so `pwm-backlight` probes
  it off. The panel enable that would light it comes after NextUI's `launch.sh`
  has unbound the driver, so nothing lit it before NextUI's own brightness.
  `rcS` lights it (`bl_power`) and mounts debugfs, where `launch.sh` reads the
  duty it carries across the unbind.
- **NextUI cleared it.** `.tmp_update/my355.sh` runs `cat /dev/zero >
  /dev/fb0` at ~2.3 s to wipe stock's splash, so the logo was erased before the
  panel ever showed it. On the vendor path the same line is harmless: that logo
  sits in the reserved `drm-logo` memory, which the kernel scans out as its own
  framebuffer, not `fb0`. NextUI now skips the clear on BaseOS.

**No earlier from the kernel side.** The vendor kernel has neither a
framebuffer console nor a kernel logo (`# CONFIG_FRAMEBUFFER_CONSOLE is not
set`, `# CONFIG_LOGO is not set`), so no command-line option draws one. Its
only logo path is taking over one a bootloader already has on the panel.
Zlyme, on a mainline kernel, does what `rcS` does: an initramfs blits a splash
into `/dev/fb0`, and it shows when the kernel lights the panel.

**Earlier means U-Boot drawing it.** Not reverse engineering: the vendor
binary's strings (`rockchip_vop2_init`, `rockchip,rk3568-video-phy`,
`panel-init-sequence`, `rockchip,drm-logo`) are Rockchip's `next-dev` display
stack, published at `rockchip-linux/u-boot`, `drivers/video/drm/`. Routes, in
order of preference:

1. The upstream VOP2 series (Dang Huynh and Ondrej Jirman, v6 of 2025-11,
   ~1,100 lines for the VOP2; unmerged, its RK3566 window choice questioned in
   review, DSI timing issues acknowledged), plus a panel driver for Rockchip's
   `panel-init-sequence` binding and the kernel hand-off, both with
   Rockchip's source as reference.
2. Port Rockchip's stack: the exact code the vendor runs, hand-off included,
   but several thousand lines against 2017 interfaces, carried forever.
3. Replay the display registers dumped from a vendor-path boot. Least code,
   most fragile, and worth having as ground truth for either of the above.

Estimated 1,500–3,000 lines, tens of blind boots. The risks are hangs in
display bring-up (save the log first; bound every wait), a wrong hand-off (the
kernel re-initialises the panel, or a black NextUI as with the planes above),
and clocks and power domains the kernel expects to inherit. The panel's own
282 ms cost ~0.3 s of boot run in line, or tens of ms overlapped with the card
read, for a logo at ~0.5–0.9 s.

## How this build works

**The secure world is the vendor's.** `mkfit.py uboot` takes the stock FIT apart
and replaces only the `uboot` image: BL31, OP-TEE and the SPL's control FDT stay
byte-for-byte, layout and `loadables` mirror the vendor's, and every image carries
the sha256 the SPL checks (it checks no signature: `## Verified-boot: 0`). The DDR
blob in `mtd5` is paired with its BL31, and the vendor kernel reaches BL31 for DDR
scaling, so U-Boot stays the only variable. `CONFIG_TEXT_BASE` is the vendor's
`0x00a00000`, the address the first build booted at.

**The boot FIT.** `mkfit.py boot` packs the vendor kernel (zstd by default,
round-trip checked) and `rk-kernel.dtb` with the same command line, SD flags and
root as the vendor path, plus the OP-TEE reservation, the VOP2 plane
assignment and the panel's shorter waits (above), read back from the written FIT. No hash nodes: bootm
treats them as optional, and a hash over the kernel is the work this path exists
to delete. A 512-byte header in front carries `MY355FIT` and the FIT's sector
count.

**The boot script**, generated by `build-uboot.sh`: `my355 cpu 1104`, `my355
fg`, `mmc dev 1`, then `part start`/`part size` to find `boot` **by name**, read the header,
check both magic words, read exactly the FIT, `bootm`. Every step after the
fuel gauge is `&&`-chained, and a failed `bootm` ends in `poweroff` rather than a dark
screen until the battery is flat. No scan, no filesystem, no environment.

| DRAM | holds |
|---|---|
| `0x02000000` | the kernel, decompressed (2 MiB-aligned; `image_size` incl. BSS checked) |
| `0x08400000`–`0x093fffff` | OP-TEE, resident; nothing may be staged here |
| `0x0a000000` | the boot FIT as read |
| `0x0c000000` | its header |
| `0x0c100000` | the console record, staged for writing (debug builds) |

`mkfit.py` owns this map, refuses any overlap, and `build-uboot.sh` bakes it into
the boot script; `build-image.sh` refuses a U-Boot built against another.

**The configuration** is `quartz64-a-rk3566_defconfig` plus
`tools/uboot/my355.config` — no scan, PCIe, USB, networking, SFC or eMMC driver,
`BOOTDELAY=-2`, `BOOTSTAGE_FDT`, zstd without `MINIFY`. `build-uboot.sh` asserts
every fragment line survives `olddefconfig`, and builds with
`SOURCE_DATE_EPOCH=0`: two builds of the same inputs give the same FIT.

**Five patches** in `tools/uboot/patches/`:

* `0001` — the `my355` command: `mark <name>` (a bootstage record from the boot
  script), `cpu <MHz>` and `fg` (above), and `log <addr> <max>` (the console
  record, for saving to the card).
* `0002` — room for the bootstage report. `image_setup_libfdt()` shrinks the
  kernel's tree to its minimum before the report is added, so only the last ten
  of ~30 records fitted and the earliest were lost; the tree is grown back by
  4 KiB inside a `CONFIG_SYS_FDT_PAD` raised to 24 KiB.
* `0003` — unaligned access for the decompressors (above).
* `0004` — the SD clock at the rate asked for (above).
* `0005` — the data cache before relocation (above).

`0004` and `0005` are the two worth sending upstream. `tools/uboot/patches-diag/`
holds the diagnostics-only patch `MY355_DIAG=1` adds on top.

## Measuring it

`baseos-bootinfo` on the device prints U-Boot's bootstage records, which it
writes into the kernel's tree at hand-off (`/proc/device-tree/bootstage`), and
`baseos-bootinfo log` the console output a debug build saved, `mmc info` and the
SD phase registers included. Build with `MY355_UBOOT_DEBUG=0` for timing boots;
the debug build costs 7 ms.

`baseos-bootinfo timeline` prints one line per boot, on the printk clock:

```
uboot 1.275  printk 1.322  init 2.121  logo 2.48  handoff 2.28  nextui 2.98  panel 2.433  frame 3.56  (card 87 ms)
```

U-Boot's hand-off, the first printk, `Run /init`, `rcS`'s logo (when `fbsplash`
returned: its pan waits for the panel), the frontend hand-off, `nextui.elf`'s
start, the panel first showing an image, NextUI's first frame, and SD card detection, with a note when
root needed a journal replay: the two known sources of kernel-phase variance.
Userspace stamps are on the uptime clock and are moved onto printk's through
the root's `jbd2` thread and its mount message, to 10 ms.

**`MY355_DIAG=1`**, given to both `build-uboot.sh` and `build-rootfs.sh`, adds
what these measurements needed and a release does not:

- U-Boot: a bootstage mark after every initcall (`patches-diag/9001`, 200
  records), which is how early init was broken down above. It reserves room for
  the marks made after `reserve_bootstage()`; without that the relocated
  bootstage block overran U-Boot's relocated device tree and the unit hung
  after relocation, dark, before the boot script (2026-09-19).
- rootfs: `baseos-frameprobe`, started by `/etc/init.d/dev`, which polls the DRM
  state every 20 ms for a plane scanning out a `nextui.elf` framebuffer and
  writes `/run/boot-first-frame`. The frame figure is an upper bound: the
  polling costs a little CPU during boot. `/run/boot-display.log` records each
  change of the backlight PWM and of whose framebuffer the panel's port scans
  out, on the uptime clock.

## Bring-up without a UART

A debug build (`MY355_UBOOT_DEBUG=1`, the default) adds the console record and
the charge LED; how to read them is in [diagnostics](diagnostics.md).

## Next, in order

U-Boot now takes 1.27 s, of which 0.54 s is the read, 0.35 s decompression and
0.20 s card init.

1. **The read**, 536 ms: SDR50 would halve it (above).
2. **Decompression**, 347 ms: at the CPU clock the vendor kernel allows.
3. **Card init**, 202 ms against the kernel's 90–220 ms; and whether the state
   U-Boot leaves the card in costs the kernel its variable detection time.
4. **`0004` and `0005` upstream**; cold boots with `MY355_UBOOT_DEBUG=0`,
   expected 7 ms faster.
5. The fuel gauge: its 13.5 ms (about 30 single-register transfers; bulk reads
   would cut them), and the resting-voltage recalibration the kernel skips once
   `FG_INIT` is set. HDMI while docked, with the plane split above.
6. A Flip control tree, for correctness: the RK8600, and none of quartz64-a's
   Ethernet, PCIe and USB.
7. A U-Boot boot logo (*The boot logo*, above), if 2.43 s is not enough.
8. Deferred: watchdog with a boot counter; USB mass storage from U-Boot.

**What mainline gives up**, accepted when it became the default on 2026-09-19: the
early boot logo (no VOP2 driver; `rcS` draws one at 2.43 s against ~1.0 s), the
low-battery guard and charge animation, the `.hdmi` device tree variant, and
`androidboot.serialno` (`usb-gadget-adb` falls back to the machine id). It also
removes `Freeing drm_logo memory`, the first-frame marker in
[boot time](boot-time.md), so compare the two paths on first printk, `Run /init`
and the `/run/boot-*` breadcrumbs.
