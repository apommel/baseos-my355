# my355 · Our own U-Boot — evaluated, not pursued

The card's `uboot` partition holds the vendor 2017.09 FIT verbatim. Replacing it
with a lean mainline build was evaluated on 2026-08-22 and **shelved**. This file
records what it would buy, what works, and the one thing that does not.

> **Provenance.** The budget figures are measured on hardware
> ([boot budget](01-boot-budget.md)). Everything about the replacement build is
> *inferred* — a FIT was built and inspected; nothing was booted from it.

## What it would buy

Of the 3.14 s pre-kernel budget, **1.21 s is the vendor U-Boot initialising before
it fetches a byte** — AVB/trusty probing, GPT repair, charge-animation, a full DRM
bring-up, a SHA1 over the whole boot image. It then reads the card at 10.9 MB/s
against the ~25 MB/s the kernel gets from the same slot.

It is also what makes zstd reachable: the Android boot image path *sniffs* the
payload (zImage → LZ4 → gzip → LZMA → none) and there is no zstd case to add. A FIT
declares `compression` per image.

Estimated total: **1.2–1.7 s**, taking power-on → NextUI input from 7.6 s to ~6.0 s.

## The risk is low, and it is not where it looks

The `uboot` partition is **on the card**. GammaLoader's SPL resolves it by name; if
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

U-Boot has a control device tree exactly as the kernel does, and the vendor U-Boot
already uses the stock `rk-kernel.dtb` from the resource image as its own. Mainline
U-Boot binds against every compatible on the boot path, because the stock DTB
carries mainline-compatible fallbacks:

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

**No reverse engineering is needed for the boot path**, and no third-party DTS. The
tree we already extract and patch in `rkbootimg.py` is the right input.

## The blocker: no VOP2 driver in U-Boot

**Mainline U-Boot v2026.07 has no display driver for this SoC.**
`drivers/video/rockchip/` stops at rk3399 — `rk3288_vop.c`, `rk3328_vop.c`,
`rk3399_vop.c` — and `vop2` appears nowhere in `drivers/`. The rk3566 handheld
defconfigs (`anbernic-rgxx3`, `powkiddy-x55`) enable `VIDEO_ROCKCHIP` and the DSI
PHY, but there is no display controller under them.

This device has no console, so a U-Boot that draws nothing leaves the panel dark
until something else lights it. A seamless boot logo therefore means **writing a
VOP2 driver**, not porting a panel node.

> **Retracted.** An earlier reading of this held that the splash was a matter of
> porting ROCKNIX's panel node and borrowing the rgxx3 video config. There is no
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

- The FIT is structurally what the SPL already loads: external-data,
  `firmware = atf-1 @ 0x40000`, `loadables = u-boot, atf-2..6`, identical ATF SRAM
  load addresses (`0xfdcc1000 / ce000 / d0000`), 1 003 008 bytes into an 8 MiB
  partition. OP-TEE absent — not required, per Experiments 3 and 6.
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
- rkbin BL31 v1.46 against GammaLoader's DDR V1.10 is unverified. The check is
  `rockchip-dmc` in dmesg — all four FSPs, no `loader&trust unmatch!!!` — as
  [SD boot](02-sd-boot.md) did for the preloader swap. Stock's own BL31 is TF-A v2.3
  (Jun 2023), so an older rkbin BL31 is the fallback.

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [our own U-Boot](09-uboot.md)
