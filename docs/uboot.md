# U-Boot

**Part 1**: tuning the vendor U-Boot — tried, measured at 22 ms, code removed.
**Part 2**: replacing it — evaluated 2026-08-22 and shelved. **Part 3**: replacing
it after all — a first build booted on 2026-09-05; this one is rebuilt from what
that taught, and is what BaseOS boots since 0.7.0. `MY355_UBOOT=vendor` builds
the vendor path. The decision is in
[decisions](decisions.md); what each is worth is in [boot time](boot-time.md).

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
asserts `root=` on each. The variant itself differs in only three properties —
the DSI endpoint `disabled`, `vcc3v3-lcd0-n` switched to `regulator-boot-off`,
and the PMIC codec `disabled` — which is stock running the TV *instead of* the
panel rather than alongside it (*The display planes*, Part 3).

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
> *The boot logo*). The logo now shows from 2.00 s.

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

# Part 3 — Mainline U-Boot, the default since 0.7.0

`./build-all.sh` builds it, or `./build-uboot.sh` then `./build-image.sh`;
`MY355_UBOOT=vendor` puts the vendor U-Boot back. It reaches `Run /init`
**1.8 s earlier** than the vendor path: 1.79–1.80 s against 3.58 s, with NextUI
starting at 2.40–2.42 s against 4.19–4.23 s (2026-09-21, three warm reboots;
U-Boot's own timings agree with cold boots). Everything below is measured on
this unit and card unless marked otherwise.

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
| quartz64-a's control tree is correct for the Flip | **wrong, replaced** | right for `sdmmc0`'s rails and card detect and the RK817's voltages, but its IO-domain map put **vccio4 in 1.8 V mode on a 3.3 V rail** until the kernel corrected it at 1.74 s; wrong for the CPU rail; and it describes Ethernet, PCIe and USB. The Flip's own tree since 2026-09-19 (*The control tree*, below) |
| its size is what makes early init slow (287 ms of driver model before relocation), so a Flip tree is the fix | **wrong** | the cost was reading any tree with the data cache off: cached, the same binding takes 9 ms (below). The Flip tree took 26 ms off, after relocation |
| early init is slow because instructions are fetched uncached | **wrong** | enabling the I-cache first thing in `board_init_f` moved no step by more than 0.5 ms: the SPL leaves it on |
| U-Boot may read the kernel at a fixed sector | **wrong** | an A/B update moves `boot` to its other half (`src/gptslot.c`: nothing in the boot chain references an address). That U-Boot would have booted the old kernel on the new rootfs |
| U-Boot init ~0.91 s, SD read ~12.7 MB/s | **measured: 0.97 s, 12.0 MB/s** | bootstage, below. The inferred split had borrowed the vendor's inflate time |
| zstd is slower than gzip on this SoC | **wrong** | U-Boot builds arm64 with `-mstrict-align`, and `ZSTD_LIB_MINIFY` defaults on; together 5.6x. Below |
| SDR50 in U-Boot needs only `mmc_of_parse()` and two Kconfig lines | **incomplete, dropped** | also a 100 MHz clock, the io-domain following vqmmc, and a power-cycled hand-off. Tried twice on 2026-09-19: the 1.8 V switch fails on cold boots, and a card cut and repowered by U-Boot no longer answers. Dropped without a UART (*The SD clock*, below) |
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
each set agreeing to 0.1 ms. The last three columns are warm reboots; U-Boot's
own stages match cold boots, the kernel phase has not been re-measured cold.
The fuel gauge step (`my355 fg`, below) came between the SD clock and early
cache columns. The `-O2` column is the release build, three warm reboots
agreeing to 0.2 ms: no debug log save, so ~7 ms of its lead over the Flip
tree column is that.

| stage | 816 MHz, gzip | 1104 MHz | zstd | SD clock | early cache | block cache | 1800 MHz decode | **Flip tree** | **zstd `-O2`** | |
|---|---|---|---|---|---|---|---|---|---|---|
| → `board_init_f` | 45 ms | 45 | 45 | 45 | 45 | 45 | 45 | 45 | 45 | |
| **pre-relocation init** | 568 ms | 566 | 569 | 570 | **40** | 40 | 40 | 38 | 38 | the data cache is off until `initr_caches()`; `dm_f` 287 → 9 ms (below) |
| post-relocation init → `main_loop` | 59 ms | 59 | 59 | 59 | 59 | 59 | 59 | **36** | 36 | 289 devices bound, then 242 (*The control tree*, below) |
| `my355 cpu 1104`, `my355 fg` | — | 2 | 2 | 2 | 16 | 16 | 16 | 16 | 17 | |
| **card init** (`mmc dev 1`) | 295 ms | 290 | 289 | 202 | 202 | **53** | 53 | 52 | 52 | 184 ms of the 202 was the partition scan (*Card init*, below); the kernel initialises the same card, SDR104 tuning included, in 75–205 ms ([boot time](boot-time.md), *The SD bus*). Why the clock fix also took 87 ms off is not established |
| **read** (header + FIT) | 1,054 ms | 1,053 | 1,063 | 536 | 536 | 534 | 534 | 534 | 534 | 12.0 MB/s, then **23.8 MB/s**: 95% of 4-bit 50 MHz |
| debug log save | 8 ms | 8 | 8 | 7 | 7 | 7 | 7 | 7 | — | the debug build's whole cost |
| **decompress** | 608 ms | 447 | 347 | 348 | 347 | 347 | **236** | 236 | **205** | gzip, then zstd |
| FIT checks, FDT fixups, hand-off | 28 ms | 13 | 12 | 12 | 12 | 12 | 14 | 14 | 14 | |
| **`start_kernel`** | 2,664 ms | 2,492 | 2,405 | 1,791 | 1,274 | 1,124 | 1,004 | **978** | **940** | |

| | vendor (docs) | 816 MHz, gzip | 1104 MHz | zstd | SD clock | early cache | block cache | 1800 MHz decode | **Flip tree** | **zstd `-O2`** |
|---|---|---|---|---|---|---|---|---|---|---|
| first printk | 2.85 s | 2.723 s | 2.537 | 2.450 | 1.837 | 1.320 | 1.171 | 1.053 | **1.027** | **0.988** |
| `Run /init` | 3.58 s | 3.654–3.670 s | 3.440 | 3.239 | 2.663 | 2.09–2.12 | 1.95–1.98 | 1.83–1.85 | **1.81–1.82** | **1.79–1.80** |
| `nextui.elf` start | 4.19–4.23 s | | | | 3.26–3.27 | 2.69–2.73 | 2.55–2.61 | 2.43–2.47 | **2.41–2.47** | **2.40–2.42** |
| first NextUI frame | — | | | | 4.09–4.10 | 3.53–3.57 | 3.16–3.19 | **2.93–2.98** | not measured | not measured |

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
`baseos-bootinfo timeline` now reports both. The five early-cache boots, as
`timeline` printed them before it gained the logo and panel columns (the third
is the outlier):

```
uboot 1.274  printk 1.320  init 2.093  handoff 2.23  nextui 2.69  frame 3.53
uboot 1.274  printk 1.321  init 2.120  handoff 2.26  nextui 2.70  frame 3.54
uboot 1.274  printk 1.321  init 2.534  handoff 2.70  nextui 3.15  frame 3.73
uboot 1.274  printk 1.321  init 2.107  handoff 2.24  nextui 2.70  frame 3.55
uboot 1.274  printk 1.321  init 2.114  handoff 2.26  nextui 2.73  frame 3.57
```

Bootstage and printk share the arch counter (hand-off at 978 ms, first printk
at 1,027 ms), but its zero is **not** power-on: `board_init_f` reads 45 ms,
after a bootrom, DDR init, SPL and BL31 the docs put at 0.39 s. Comparisons
between the two paths hold, because everything before U-Boot is identical on
both; "power-on-relative" elsewhere in these docs means "since the counter
started". Open.

## The CPU clock

`my355 cpu 1104` (patch `0001`) runs before the card is touched: it checks the
RK8600's ID, reads VSEL0 (712.5 mV + 12.5 mV per step, 6-bit, confirmed against
the kernel's own reading), raises it to the rate's voltage from the vendor OPP
table only if it is lower (never lowering it), then sets `ARMCLK` and reads it
back. At 1104 MHz that is 900 mV, and the rail already sits at 1000 mV, so it
only sets the clock. **The kernel never gets more than 1104 MHz**: the vendor
kernel sets `vdd_cpu` to its `regulator-init-microvolt` of 900 mV when the
regulator probes, before cpufreq, so a faster hand-off would be under-volted
for that window.

Inflate 608 → 447 ms, first printk 2.723 → 2.537 s. The kernel phase moved less
than predicted (0.94 → 0.90 s) because it now waits on the SD card: detection
took 212 ms on that boot against 90 ms on an earlier one.

**Decompression at 1800 MHz (2026-09-19).** The boot script runs `bootm` in its
steps: `my355 cpu 1800`, `bootm start` (finding the kernel and tree in the
FIT), `bootm loados` (the decompression), then `my355 cpu 1104`, `bootm prep`
and `bootm go`. A failed return to 1104 MHz stops the chain, and the board powers off rather than
hand over a fast clock; a failed raise only leaves decompression at 1104.
Voltages are the vendor OPP table's default column (L0), which covers every
silicon bin: 1025 mV at 1416 MHz, 1100 at 1608, 1150 at 1800, against this
unit's L3 bin at 925/1000/1050. U-Boot's clock tables stopped at 1416 MHz;
patch `0006` adds Linux's 1608 and 1800 MHz rows.

| decompression at | `fit_read` → `decompressed` | `start_kernel` |
|---|---|---|
| 1104 MHz | ~363 ms | 1,124 ms |
| 1416 MHz | 297 ms | 1,058 ms |
| **1800 MHz** | **243 ms** | **1,004 ms** |

Near-linear in the clock. The window includes the debug log save (7 ms), the
voltage ramp and `bootm start`; `prep` and `go` back at 1104 MHz take 14 ms.
Since `my355 cpu` never lowers the rail, the kernel receives 1104 MHz at
1150 mV, over-volted rather than under, until its regulator probe sets 900 mV
as before.

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

## Kernel compression, revisited

Re-run on 2026-09-21, once the read had doubled to 23.8 MB/s and decompression
moved to 1800 MHz, both of which shift the trade between size and decode
speed. Every format `bootm` accepts, 74 encodings in all, was timed with U-Boot's
own decoders on the device at 1800 MHz and DDR pinned at 1056 MHz, the output
checked against the vendor `Image` (`tools/uboot/decomp-bench/`). The bench
read 227 ms for the shipped file against bootstage's 236. The read is charged at
bootstage's 534 ms for 12.73 MB. Four decoder builds:

* **S**, as shipped: `-Os`, and `-mstrict-align` everywhere but zstd and zlib
* **U**, every decoder without `-mstrict-align`
* **M**, U, and lz4's fixed-size copies as `__builtin_memcpy`: with
  `-fno-builtin` they otherwise call `lib/string.c`'s `memcpy`, which goes
  byte by byte unless both pointers are 8-byte aligned
* **O**, M at `-O2`

Best encoding per format, read + decode, in ms:

| format | S | U | M | O |
|---|---|---|---|---|
| **zstd** | 755 | 754 | 755 | **725** |
| lz4 `-12`, 4 MiB blocks (15.52 MB) | 973 | 945 | 735 | 732 |
| lzo `-9` (14.56 MB) | 790 | 763 | 766 | 770 |
| gzip, libdeflate `-12` (12.50 MB) | 787 | 781 | 785 | 787 |
| lzma, `lp=2,pb=2` (9.25 MB) | 1,685 | 1,687 | 1,686 | 1,703 |
| bzip2 `-9` (12.19 MB) | 5.78 s to decode alone | | | |

* **zstd stays.** Across level 19/22, windows 2^17–2^23 and minimum matches
  4–7, the best settings sit within 10 ms of each other, and within 7 ms of the
  shipped one (762 ms), which is kept.
* **`-O2` is the lever**: the decoder is 13% faster (228 → 196 ms on the
  shipped file) for 10 KB of code. Patch `0007` builds `lib/zstd` so.
* **lz4 is now close, not better.** Fixed, it decodes in 79 ms instead of 328,
  but it is 2.9 MB larger than zstd, and its total rests on the read
  scaling linearly to that size; zstd's gain is decode alone, measured.

Booted, three warm reboots: `bootm_load_os` 223.9 → **193.5 ms**,
`start_kernel` 971 → **940 ms**, `Run /init` 1.79–1.80 s.

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

The next doubling is SDR50: 100 MHz at 1.8 V, no tuning needed. **Tried twice
on 2026-09-19 and dropped**; the code is not in the tree. It took:
`sd-uhs-sdr50` in place of `sd-uhs-sdr104` in U-Boot's tree (U-Boot's dw_mmc
cannot tune), `mmc_of_parse()` in the Rockchip glue, a 100 MHz clock from the
400 MHz source divided by the controller, and the pads' io-domain setting
following vqmmc, which U-Boot's io-domain driver only writes at probe.

On a warm reboot it worked: `Mode: UHS SDR50 (100MHz)` and the whole FIT read
back. Three things stopped it:

- **The hand-off.** Only a power cycle ends 1.8 V signalling, and the vendor
  kernel cannot power the card: its `vcc_sd` names its pin `enable-gpio`,
  which `regulator-fixed` does not read (stock shows it with no state). A card
  U-Boot leaves off stays off, and one left at 1.8 V was not recovered.
- **U-Boot cannot power-cycle the card.** `vcc3v3_sd` is counted: one reference
  from `regulator-boot-on`, one per MMC power-on, and disabling returns
  `-EBUSY` until all are dropped. The MMC core's own power cycle is a no-op,
  so its fallback after a failed 1.8 V switch (power-cycle, retry at 3.3 V)
  cannot work either.
- **Cold boots failed in card init** (charge LED still lit, no log saved), for
  a reason not established; the unrecoverable fallback turned that into a
  power-off.

The second attempt, on the Flip's own tree, cut `vcc_sd` itself after the
read (dropping each counted reference), kept it off through decompression and
restored it before the hand-off. It added a retry at high speed, and a
`sleep` pin state pulling the card's lines down while it was off, so their
pull-ups to `vccio_sd` could not power it through its I/O pins. It found:

- **A warm reboot still read the FIT at SDR50, then hung in the kernel**: the
  card, cut for ~240 ms with its pins left as they were and repowered, did not
  answer. The cut with the pins pulled down was never reached: every boot of
  that build was cold, and failed earlier.
- **Cold boots fail the switch itself**, in the first card init: every cold
  boot tried, in both attempts. Why is not established.
- **A forced high-speed retry does not avoid it.** `mmc_get_op_cond()` requests
  1.8 V from the board's capabilities, not the mode `mmc dev 1 0 2` forces, so
  the retry switched and failed the same way. A real fallback has to clear the
  UHS capabilities first.
- **Neither failure can be logged.** Both leave the card, the only place a log
  can go, unusable; a record kept in DRAM across `reset` did not survive
  ([diagnostics](diagnostics.md)).

Dropped: at most ~0.26 s, and each attempt blind, costing a trip through
stock. A retry needs a UART first. Even working, it would hand the kernel a
freshly powered card, costing card init just before the root mount, and read
at 100 MHz on a fixed, untuned sample phase, which may not hold across cards.

## Card init: the partition scan

`mmc dev 1` took 202 ms, against ~77 ms for the kernel on the same card. The
card was not the cause. With `patches-diag/9002` (2026-09-19), init proper
took 40 ms and the card was ready at the first ACMD41 poll. The other 184 ms
came after it: probing the block device runs `part_init`, then
`part_create_block_devices` looks up each of the 128 GPT entry slots, and each
lookup re-reads the 20-block entry array at 1.19 ms. U-Boot's block cache
keeps reads of up to 8 blocks only, so none of them hit.

`blkcache configure 32 32` in the boot script, before `mmc dev 1`, lets the
cache hold the array (32 blocks covers a full 128-entry one; at most 512 KiB
of the 32 MiB heap). `mmc dev 1` is 53 ms, the scan's lookups 13 ms, and
`start_kernel` moved 1,274 → 1,124 ms, which carried through to `Run /init`
and the first frame. `blkcache` only adds and reads cache entries; a `mmc
write` (the debug log) invalidates them.

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

Verified 2026-09-19: five cold boots, a warm reboot and a cold boot with the
charger attached; since 2026-09-21, charger-woken power-ons too (*Charging
while off*). Worth **530 ms**, carried unchanged to the first frame. A
failure would look like the dark screen of the first diagnostics build: a hang
before the boot script, which the SPL does not catch because the FIT is valid,
recovered by re-flashing or from stock with the card in the left slot.

It is the best candidate to send upstream with `0004`, generalised to Rockchip
arm64.

## The control tree

U-Boot's control tree was quartz64-a's until 2026-09-19. It is now the Flip's:
`tools/uboot/dts/rk3566-miyoo-flip.dts`, over the SoC's `rk3566.dtsi`, with
values from the vendor kernel's tree and nothing U-Boot does not use:

- **the boot slot** (`sdmmc0`), its pins, `vcc_sd` (gpio0 PA5, active low)
  and `vccio_sd` as its supplies;
- **the RK817**, for `poweroff` and five of its rails: the supplies of the IO
  domains and the card. The rest are left as the PMIC has them;
- **the IO domains**, with the Flip's map;
- **UART2**, as the console.

quartz64-a's rails matched the Flip's, down to the RK817's voltages, but its IO
domains did not. U-Boot sets each domain's pad voltage as it binds the node,
and quartz64-a feeds vccio4 from `vcc_1v8` where the Flip feeds it `vcc_3v3`.
So every boot held vccio4 in 1.8 V mode on a 3.3 V rail from U-Boot until the
kernel's driver probed at 1.74 s. The kernel's own log confirms the Flip's map
(`vccio4(3300000 uV) supplied by vcc_3v3`). Rockchip's hardware design guide
requires the setting to match the supply.

Dropping quartz64-a's Ethernet, PCIe, USB, SDIO, audio and display nodes
took init after relocation from 59 to 36 ms. U-Boot now binds 242 devices
where it bound 289, and probes one SD controller instead of two. The hand-off
moved 1,004 → 978 ms over five warm reboots, each agreeing to 0.1 ms.

The file is copied into U-Boot's tree on every build rather than patched in,
and `CONFIG_OF_UPSTREAM` is off. That is how `rk3568-generic`, U-Boot's
minimal tree for this SoC, is built. `quartz64-a-rk3566_defconfig` remains the
Kconfig base.

## What the kernel relied on the vendor U-Boot for

The vendor U-Boot edits the kernel's world before hand-off, and the vendor
kernel depends on each edit without saying so. Mainline does none of them, so
this path does each one itself. Four are known, each found by its failure.

| the vendor U-Boot | without it, on mainline | done here by |
|---|---|---|
| splits `/memory` around OP-TEE at `0x08400000` | the kernel allocates over resident secure firmware and dies after `Starting kernel` (2026-08-24) | `mkfit.py boot`: a `/reserved-memory` `no-map` node |
| writes `rockchip,plane-mask` and `rockchip,primary-plane` into each VOP2 port (`rk3568_assign_plane_mask`) | the kernel's default gives the panel's port (`vp1`) the RK3566's mirror windows, which scan out nothing: **NextUI runs, the panel is black with the backlight on**. dmesg: `current plane mask: 0x0 … use default plane mask` | `mkfit.py boot`: a main window of its own for each display (below) |
| reconciles the RK817 fuel gauge and sets `FG_INIT` (`fg_rk817.c`) | the kernel reads charge gained while off as a halted session and restarts the displayed SOC from **0% on a full battery**; a low-battery shutdown would follow unplugged | `my355 fg`, in the boot script |
| refuses to let a *fallen* counter move that SOC (`rk817_bat_not_first_pwron`) | the counter does not survive a power-off and nothing contradicts it: **11% on a battery at 4.2 V** | `my355 fg`: only a rise is believed, and it is charge gained while off |

**The display planes.** The RK3566's VOP2 has six windows but only three that
can source a buffer: Cluster1, Esmart1 and Smart1 have no framebuffer of their
own, they only mirror Cluster0, Esmart0 and Smart0. Upstream refuses to register
them at all (`vop2_is_mirror_win`, soc_id 3566); the vendor kernel takes
`rockchip,plane-mask` per port and trusts what it is given.

The vendor U-Boot gives one port every main window and the other every mirror —
the panel `0x15`, HDMI `0x2a` — so whichever display holds the mirrors scans out
the *other* one's buffer at its own stride. On a TV that is the boot logo
duplicated and torn, and nothing the frontend draws ever appears. Stock avoids
this by never running both at once: `rk-kernel.dtb.hdmi` disables the DSI
endpoint and powers the panel rail down, leaving HDMI the only display. That is
why stock rebooted to switch to a TV, and why hot-plugging it could not work.

This path splits the windows instead. The panel takes `0x30` (Smart0 as primary,
plus its mirror Smart1), HDMI `0x0f` (Esmart0 as primary and Cluster0, with
theirs). Each display drives a main window of its own, so both run at once with
independent content, and plugging a cable in is an ordinary modeset on a port
that already owns its window. Esmart0 takes the TV because it is primary-capable
and scales 8x either way, against Cluster0's 4x; the frontend renders 1280x720
natively, so the scaler is there for what a core hands it. Measured against the
mirrored split, `dclk_vop0`, `dclk_vop1`, `aclk_vop` and the DDR frequency are
unchanged: both ports were always clocked and always fetching, a mirror window
simply fetched the wrong address.

Every window has to be assigned. The kernel checks the masks against `0x3f` and
silently falls back to its own default if any is missing — `all windows should
be assigned, full plane mask: 0x3f, current plane mask: 0x15 … use default plane
mask`, which hands one port the mains and the other the mirrors again. So
`set_vop2_plane_masks` refuses a split that does not cover all six or that
assigns a window twice, finds each encoder's VOP port from the tree's endpoints
rather than assuming it, and refuses a tree that already assigns planes. No
`.hdmi` tree variant is needed.

Cold-plug, hot-plug and hot-unplug were all verified on this split. Following
`card0-HDMI-A-1/status` and moving between the two is the frontend's own work;
this only makes both connectors usable at once.

**The fuel gauge.** The RK817 keeps its state across power-off in PMIC
registers: a coulomb counter, and the SOC and capacity the kernel last saved.
Left alone, the kernel compares the two, and a gap over 10% of FCC — charging
while off gives one — it takes for a crash, restarting from an `rsoc` it has not
yet computed: 0. NextUI's battery log on this unit shows it happening, 78 → 54
→ 0 → creeping up 1% at a time on a battery at 4.19 V. `my355 fg` (patch
`0001`) writes a SOC, capacity and counter of its own and sets `FG_INIT`, which
tells the kernel to take them (`rk817-bat: initialized yet..`).

The rule it applies is the vendor U-Boot's, from
[`fg_rk817.c`](https://github.com/rockchip-linux/u-boot/blob/next-dev/drivers/power/fuel_gauge/fg_rk817.c)
`rk817_bat_not_first_pwron()`: **only a rise in the counter is believed.**

```c
if ((now_cap > 0) && (now_cap > pre_cap + 10)) {   /* charged while off */
        now_soc = now_cap * 1000 * 100 / battery->fcc;
        if (pre_soc < 100 * 1000)
                pre_soc += (now_soc - pre_cap * 1000 * 100 / battery->fcc);
        pre_cap = now_cap;
}
rk817_bat_init_coulomb_cap(battery, pre_cap);
```

A rise is charge gained while off, which is real and which the kernel would
otherwise read as a crash. Anything else — and that includes every fall — keeps
the SOC and capacity the kernel last saved, and re-seeds the counter from them.
The counter is never allowed to move the SOC down across a boot.

That is the whole mechanism, and it holds because of what each source is worth
at that moment. **The counter does not survive a real power-off**: measured on
this unit, 4h20m off cost 112 mAh, ~9.4 h cost 2,670, and 70 min cost 284 — no
rate, no bound, and always downward. Far enough down it goes negative, which
sets bit 31 of `Q_PRES`, the bit the driver calls `CAP_INVALID`; the vendor
reads such a counter as 0, which is not a rise, so the saved state is kept like
after any other fall. **The saved SOC does survive**: it is what
the kernel computed while running, when the counter was working, and nothing
that happens with the rails down can invalidate it except charging, which shows
up as the rise. A battery reconnected from empty (`BAT_CON`) has no saved state
and is left to the kernel, which is the vendor's `rk817_bat_first_pwron` case
and the only one that reads the power-on voltage.

The power-on voltage is deliberately **not** used for the SOC. (The
low-battery guard reads it only as a floor, *Charging while off*.) `PWRON_VOL`
against the cell's `ocv_table` was tried and rejected: it reads accurately at
the top of the curve but not in the middle, where it put a cell the counter had
tracked down to 75% at 92% ([history](history.md), 2026-09-20). That is the
failure the [Zetarancio
notebook](https://github.com/Zetarancio/Miyoo-Flip-Mainline-Linux-Reverse-Engineering/blob/main/docs/miyoo-flip-power-off-investigation.md#re-verification-2026-08-27)
documents from the other direction, retracting its own "37.5 mA drain" as a
boot-time OCV re-seed reading low.

It never leaves the kernel to decide on its own, because the kernel's only
answer to an unexpected counter is the halt path and 0%: an out-of-range `fcc`
is replaced by the design capacity or `qmax`, as the vendor's `rk817_bat_get_fcc()`
does. Only an unreadable PMIC is handed over.

The kernel's charger driver sets input and charge limits itself from its tree
(`rk817_charge_pre_init`), so nothing else of `fg_rk817.c` is needed. Each
register is read in one multi-byte transfer: verified on this unit to match
byte-by-byte reads, and `rk817_get`'s two-byte ID read fails the command if the
PMIC ever stopped auto-incrementing. The decision itself is
`rk817_fg_decide()`, which `tests/test-fuel-gauge.sh` compiles as it stands.
The log line carries both readings and which way it went:

```
my355 fg: soc 74.999 -> 74.999%, cap 2346 -> 2346 mAh of 3000, off 7, cnt 2062 mAh
```

`cnt` is what the counter made of it and is only ever reported unless
`(charged while off)`, `(counted while up)` or `(charged to full)` appears, in
which case it is what moved the SOC. `off` is
`OFF_CNT`, which is reported but not acted on: its step is about ten minutes,
not the minute the vendor driver reads it as, so the vendor kernel's own
`pwroff_min >= 30` gate is really about five hours.

## Charging while off

The RK817 charges with the SoC off: on 2026-09-21 a unit charged while off
booted with `CHRG_STS` at *terminated* and the counter up
(`charged while off`). The charge LED, though, is a SoC pin (`gpio0 PC2`), so
with the SoC off it stays dark. Stock keeps its U-Boot running to light it and
draw the battery screen; `my355 charge`, first in the boot script, does the
same without the screen:

- **When.** The PMIC was started by the charger (`ON_SOURCE` bit 6), the
  kernel restarted with `reboot charge`, or the battery is too flat to boot
  (below). `ON_SOURCE` survives a reboot, so it only counts on a cold start,
  which the reboot-mode register tells apart: 0 then, `0x5242c3xx` once U-Boot
  or the kernel has run. U-Boot's own boot-mode handling is off
  (`ROCKCHIP_BOOT_MODE_REG=0x0`) because it would clear the register first.
  Every other boot costs a few I2C transfers.
- **Too flat to boot**, on a cold start: `BAT_VOL` and `PWRON_VOL` both under
  3400 mV, the vendor tree's `uboot-low-power-voltage` of 3350 plus the 50 the
  vendor adds, converted as the kernel does. `BAT_VOL` is switched to single
  samples first (`GG_CON` bit 1), as the vendor U-Boot does: the kernel keeps
  it averaged, and the average still holds readings from before the power-off
  (3926 mV on a battery the kernel then read at 4086). The kernel's probe
  switches it back. Both readings must still agree, because the first sample
  may not be ready yet and a false alarm would keep the unit from booting. It
  is `PWRON_VOL` that decides in practice: U-Boot's own load pulls `BAT_VOL`
  down, by 26 mV at 99% and 96 mV at 11% on this unit, so at 11% the two read
  3388 and 3484 mV around a 3400 mV threshold and the boot went through.
  `PWRON_VOL` is not frozen at power-on either — while running at 10% it read
  3707 mV against `BAT_VOL`'s 3691 — so both inputs follow the battery. Without a
  charger the charge LED blinks three times and the board powers off, as the
  vendor's `charge_extrem_low_power()` does; with one, charge mode starts and
  the power key is refused until `BAT_VOL` is back over 3400 mV. A warm reboot
  is never refused: its `PWRON_VOL` dates from the cold start, and the kernel
  has its own low-voltage shutdown.
- **Shut down with the charger in.** The PMIC powers off and no plug-in event
  ever wakes it. `/usr/sbin/poweroff` (the one NextUI runs) flags it with the
  charger online, and `rcK` then ends in `rebootmode charge` instead: a
  `LINUX_REBOOT_CMD_RESTART2` that busybox cannot issue. The vendor kernel lists
  `charge` among the reboots that keep the PMIC up, and its reboot-mode driver
  writes `0x5242c30b` to `PMU_GRF_OS_REG0`.
- **The charge current.** The PMIC powers on limiting its input to 450 mA, so
  the first charge-mode session measured ~340 mA reaching the battery once the
  SoC had taken its share: 113 mAh in 20 minutes (2026-09-22). The kernel
  raises the limits at probe, which is why charging is fast under BaseOS, and
  the vendor U-Boot raises them too. `my355 charge` now writes the same
  `USB_CTRL` the kernel ends up with — input 1500 mA, input voltage floor
  4.5 V — and, like the vendor, leaves the charge current register alone: it
  only sets that from a temperature-compensation table the Flip's tree does
  not have. The floor is what makes 1500 mA safe on a port that cannot supply
  it, since the PMIC backs off as the source sags; the vendor would use 450 mA
  for a port its USB detection calls a plain one, which needs a USB PHY driver
  this build does not have. Both registers are logged.
- **Then** the `work` LED (`gpio0 PB4`, lit from power-on) goes off, and
  every 100 ms the charge LED follows `CHRG_STS`: lit for dead, trickle and
  CC/CV, dark while a charge is paused or refused, which the PMIC resumes on
  its own. The PMIC is powered off when it reads terminated or when the cable
  is pulled; U-Boot stays up otherwise, powered by the charger. Holding the
  power key for 2 s, the vendor's `KEY_LONG_DOWN_MS`, boots instead, with the
  `work` LED lit again: `INT_STS0` latches the press (`PWRON_FALL`) and the
  release (`PWRON_RISE`), both cleared as they are read, and both in one poll
  count as a short press.
- **Powering off** clears `SYS_CAN_SD` (`0xe6` bit 7) first. A battery
  reconnect sets it, and while set it costs ~8 mA off (the
  [Zetarancio notebook](https://github.com/Zetarancio/Miyoo-Flip-Mainline-Linux-Reverse-Engineering/blob/main/docs/miyoo-flip-power-off-investigation.md));
  the vendor U-Boot and kernel clear it at probe, but charge mode can power
  off before the kernel has ever run.
- **The gauge.** Unlike a real power-off, the counter works while U-Boot runs,
  so `my355 fg`'s bookkeeping runs on entry and again on exit, and on exit any
  change is taken, not only a rise over 10 mAh (`(counted while up)`). The exit
  is where the charge is saved as SOC, before the counter decays with the rails
  down; a boot by the power key saves it the same way first. A terminated
  charge writes 100% and the full capacity (`(charged to full)`).

It runs at the least the SoC allows without new drivers: the one core U-Boot
uses at 408 MHz and `vdd_cpu` at 850 mV (the vendor's floor for every bin, down
from the RK8600's 1000 mV at power-on), and parked in WFE between polls, woken by
the timer's event stream every 1.4 ms rather than spinning. The boot path puts
both back up (`my355 cpu 1104`). Not done: the DDR stays at its trained rate
(lowering it goes through BL31), and the GPU and logic rails stay up.

Against the vendor's
[`charge_animation.c`](https://github.com/rockchip-linux/u-boot/blob/next-dev/drivers/power/charge_animation.c),
two deliberate differences. The vendor stays up once full, handing over to
a *charging-full* LED the Flip does not have; this powers off, as dark as a
normal shutdown. And the vendor idles in PSCI system suspend, with
the regulators in their sleep states, which needs interrupts and a wake-up
source mainline U-Boot does not have here; WFE is the step short of that. The
rest matches: the 2 s press to boot, the exit on unplug, the low-battery
guard, `reboot charge` (`BOOT_CHARGING`, cleared once read), the gauge saved before powering off, and on termination the full
capacity loaded into the counter (`rk817_bat_finish_chrg`), though the vendor
walks the SOC up to 100% where this writes it at once.

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
| **logo on the panel** (`dw_mipi_dsi_bridge_enable`) | **2.43 s**, was 2.99; 2.00 s since (below) | ~1.0 s |
| NextUI sets its brightness | 2.96 s | |
| first NextUI frame | 3.56 s | 5.72–5.75 s |

So the logo was up for about 1.1 s, arriving 1.4 s after the vendor's; since
the changes below, it arrives at 2.00 s, about 1.0 s after the vendor's. It
took three fixes, each found on the device with `baseos-frameprobe` (below):

- **The panel's waits.** The kernel switches the panel's supply on at 2.02 s,
  then waits `reset-delay-ms` 160, `init-delay-ms` 200, the init sequence's own
  250 + 32 and `enable-delay-ms` 200 before the DSI link streams a pixel. There
  is no reset line, so the first two only wait out power-on. The boot script
  now powers the panel first (`gpio set A23`, gpio0 PC7, `vcc3v3_lcd0_n`), and
  `rkbootimg.set_panel_delays` sets 160/200/200 to 0/20/0: the link streams at
  2.43 s against 2.99. The init sequence's 250 ms after sleep-out (DCS
  `0x11`) is now 120 ms, the usual requirement: 2.29 s in 12 warm boots
  (2.286–2.311 s), and cold boots showed a clean image each time. 2.15 s
  since the block cache took 150 ms off U-Boot, 2.03 s since decompression
  runs at 1800 MHz, 2.00–2.01 s with the Flip control tree.
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

**What binds the display at ~2.0 s.** The DSI host looks for its panel at
1.73 s, before `panel-simple` has registered (link order), and defers. This
5.10 kernel retries deferred devices only at `deferred_probe_initcall`, once
every built-in driver has initialised, at ~2.02 s. Dropping the panel
regulator's `vin-supply` (the PMIC's `vcc_3v3`, which the regulator also
deferred on) was tried: bind 15 ms earlier, panel unchanged. Only a shorter
driver-init phase would move it.

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
152 ms (120 + 32) would cost ~0.2 s of boot run in line, or tens of ms
overlapped with the card read, for a logo at ~0.5–0.9 s.

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
assignment and the panel's shorter waits (above), read back from the written
FIT. No hash nodes: bootm treats them as optional, and a hash over the kernel
is the work this path exists to delete. A 512-byte header in front carries `MY355FIT` and the FIT's sector
count.

**The boot script**, generated by `build-uboot.sh`: `my355 charge` (*Charging
while off*), power the panel,
`my355 cpu 1104`, `my355 fg`, `blkcache configure`, `mmc dev 1`, then `part
start`/`part size` to find `boot` **by name**, read the header, check both magic
words, read exactly the FIT, then `bootm` in its steps with the decompression
at 1800 MHz (*The CPU clock*). The steps before the card are allowed to fail;
every step from `mmc dev 1` on is `&&`-chained, and a failed `bootm`, or a
clock that will not come back to 1104 MHz, ends in `poweroff` rather than a
dark screen until the battery is flat. No scan, no filesystem, no environment.

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
`tools/uboot/my355.config`, over the Flip's own control tree (above): no scan,
PCIe, USB, networking, SFC or eMMC driver, `BOOTDELAY=-2`, `BOOTSTAGE_FDT`,
zstd without `MINIFY`, and the block cache the boot script configures. `build-uboot.sh` asserts
every fragment line survives `olddefconfig`, and builds with
`SOURCE_DATE_EPOCH=0`: two builds of the same inputs give the same FIT.

**Seven patches** in `tools/uboot/patches/`:

* `0001` — the `my355` command: `mark <name>` (a bootstage record from the boot
  script), `cpu <MHz>`, `fg` and `charge` (above), and `log <addr> <max>` (the console
  record, for saving to the card).
* `0002` — room for the bootstage report. `image_setup_libfdt()` shrinks the
  kernel's tree to its minimum before the report is added, so only the last ten
  of ~30 records fitted and the earliest were lost; the tree is grown back by
  4 KiB inside a `CONFIG_SYS_FDT_PAD` raised to 24 KiB.
* `0003` — unaligned access for the decompressors (above).
* `0004` — the SD clock at the rate asked for (above).
* `0005` — the data cache before relocation (above).
* `0006` — the RK3568's 1608 and 1800 MHz CPU rates (*The CPU clock*).
* `0007` — the zstd decoder at `-O2` (*Kernel compression, revisited*).

`0004`, `0005` and `0006` are the ones worth sending upstream.
`tools/uboot/patches-diag/` holds the diagnostics-only patches `MY355_DIAG=1`
adds on top.

## Measuring it

`baseos-bootinfo` on the device prints U-Boot's bootstage records, which it
writes into the kernel's tree at hand-off (`/proc/device-tree/bootstage`), and
`baseos-bootinfo log` the console output a debug build (`MY355_UBOOT_DEBUG=1`)
saved, `mmc info` and the SD phase registers included. The default release
build saves none; the debug build costs 7 ms, and the timings on this page are
from debug builds except the `-O2` column.

`baseos-bootinfo timeline` prints one line per boot, on the printk clock:

```
uboot 1.275  printk 1.322  init 2.121  logo 2.48  handoff 2.28  nextui 2.98  panel 2.433  frame 3.56  (card 87 ms)
```

U-Boot's hand-off, the first printk, `Run /init`, `rcS`'s logo (when `fbsplash`
returned: its pan waits for the panel), the frontend hand-off, `nextui.elf`'s
start, the panel first showing an image, NextUI's first frame, and SD card
detection, with a note when root needed a journal replay: the two known sources of kernel-phase variance.
Userspace stamps are on the uptime clock and are moved onto printk's through
the root's `jbd2` thread and its mount message, to 10 ms.

**`MY355_DIAG=1`**, given to both `build-uboot.sh` and `build-rootfs.sh`, adds
what these measurements needed and a release does not:

- U-Boot: a bootstage mark after every initcall (`patches-diag/9001`, 200
  records), which is how early init was broken down above. It reserves room for
  the marks made after `reserve_bootstage()`; without that the relocated
  bootstage block overran U-Boot's relocated device tree and the unit hung
  after relocation, dark, before the boot script (2026-09-19).
- U-Boot: a mark at each step of `mmc dev 1` and around the partition scan,
  the ACMD41 poll count, and every block read's duration in the console
  record (`patches-diag/9002`, *Card init*).
- Writing ~150 records into the kernel's tree costs **~120 ms after the
  `start_kernel` mark**: compare the first printk, not the hand-off, against a
  build without it.
- rootfs: `baseos-frameprobe`, started by `/etc/init.d/dev`, which polls the DRM
  state every 20 ms for a plane scanning out a `nextui.elf` framebuffer and
  writes `/run/boot-first-frame`. The frame figure is an upper bound: the
  polling costs a little CPU during boot. `/run/boot-display.log` records each
  change of the backlight PWM and of whose framebuffer the panel's port scans
  out, on the uptime clock.

## Bring-up without a UART

A debug build (`MY355_UBOOT_DEBUG=1`; the default `0` is the release build)
adds the console record and the charge LED; how to read them is in
[diagnostics](diagnostics.md).

## Next, in order

**Before 0.7.0 ships:**

1. **Cold boots of the release build.** Its timings above are warm reboots;
   the debug builds before it matched cold boots to 0.1 ms.
2. **The untested paths:** charge mode's 2 s power key, a charge left paused,
   and the low-battery guard with and without a charger (*Charging while
   off*), and an update from 0.6.0, which swaps the vendor
   `uboot` and `boot` slots for these in one step.
3. **NextUI's `my355.sh` change**, which stops it clearing `/dev/fb0` on
   BaseOS, in the NextUI release users will run. Without it the `rcS` logo is
   erased before the panel shows it.

**Speed.** U-Boot now takes 0.94 s, of which 0.53 s is the read, 0.20 s
decompression and 0.12 s init before the boot script.

4. **The read**, 534 ms: SDR50 would halve it, but was dropped (above), and
   50 MHz is the limit at 3.3 V. Fewer bytes are not on offer either: every
   format was re-measured at today's read speed and clock, and zstd stays
   (*Kernel compression, revisited*).
5. **Decompression**, 194 ms at 1800 MHz (*The CPU clock*). Overlapping it with
   the read would need a second core started through BL31: up to ~200 ms, but
   its own MMU and cache setup, and a hang there would be invisible.
6. **Card init**, 53 ms: `mmc_go_idle` 11 ms and `sd_select_mode_and_width`
   16 ms are the largest steps left, and the partition scan's 128 cached
   lookups 13 ms.

**Upkeep:**

7. **`0004`, `0005` and `0006` upstream.**
8. The fuel gauge: the resting-voltage recalibration the kernel skips once
   `FG_INIT` is set, so discharge while off is not seen until the kernel's
   own low-voltage handling. Its 13.5 ms should drop with multi-byte reads:
   re-measure.
9. A U-Boot boot logo (*The boot logo*, above), if 2.00 s is not enough. The
   cheaper levers for it are everything before `start_kernel`, which moves it
   one for one, and the kernel's `rk3x_i2c_driver_init` (146 ms in the last
   `initcall_debug` profile, [boot time](boot-time.md)): re-profile first.
10. Deferred: watchdog with a boot counter; USB mass storage from U-Boot.

**What mainline gives up**, accepted when it became the default on 2026-09-19:
the early boot logo (no VOP2 driver; `rcS` draws one at 2.00 s against ~1.0 s),
the charge animation's screen (its LED and the low-battery guard are kept,
*Charging while off*), and `androidboot.serialno`
(`usb-gadget-adb` falls back to the machine id). The `.hdmi` device tree variant
is not given up but obsolete: the plane split above runs both displays at once,
which is what stock used that variant to avoid having to do. It also
removes `Freeing drm_logo memory`, the first-frame marker in
[boot time](boot-time.md), so compare the two paths on first printk, `Run /init`
and the `/run/boot-*` breadcrumbs.
