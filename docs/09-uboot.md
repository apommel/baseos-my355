# my355 · U-Boot

Two separate questions, both settled on 2026-08-22. **Part 1**: tuning the vendor
U-Boot — tried, measured at 22 ms, code removed. **Part 2**: replacing it —
evaluated, shelved.

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
| enable `crypto@fe380000` (the binary logs `Can't find crypto device for SHA1`) | untested |

Pre-kernel went 3.14 s → **3.118 s**. Not worth carrying.

The SD result is the useful one. The theory was that U-Boot attempts UHS, fails the
1.8 V switch and falls back to legacy 25 MHz — which is where the measured
10.9 MB/s sits, against the kernel's ~25 MB/s. The edit provably reached U-Boot's
tree (the kernel's own mode changed from `sd uhs SDR25` to `new high speed SDXC
card`, both 50 MHz) and the budget did not move. **So the slow read is not a UHS
fallback**; the cause is inside the binary — transfer sizes, no DMA, or the SHA1 —
and unreachable from a device tree. Halving that 1.19 s needs Part 2.

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

# Part 2 — Replacing it (evaluated, not pursued)

The card's `uboot` partition holds the vendor 2017.09 FIT verbatim. Replacing it
with a lean mainline build was evaluated and **shelved**.

> **Provenance.** Budget figures are measured on hardware. Everything about the
> replacement build is *inferred* — a FIT was built and inspected; nothing was
> booted from it.

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

## The zero-RE option, if this is revisited

Lean U-Boot + stock DTB + **no video at all**, drawing the splash from the kernel
side with the `baseos-splash` fbsplash the rootfs already ships. Cost is cosmetic
and bounded: the logo appears at ~2.9 s instead of ~1.0 s while the whole boot drops
to ~6.0 s.

The real cost is **blind iteration**: no console without opening the case, so a
U-Boot that dies early is indistinguishable from one that never started. Mitigable
by toggling the `work` LED at known stages, as
[bring-up](07-bringup-and-diagnostics.md) does for the kernel.

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
  [SD boot](02-sd-boot.md) did for the preloader swap. Stock's own BL31 is TF-A v2.3
  (Jun 2023), so an older rkbin BL31 is the fallback.

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
