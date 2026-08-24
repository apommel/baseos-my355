# my355 · U-Boot

Three parts. **Part 1**: tuning the vendor U-Boot — tried on 2026-08-22,
measured at 22 ms, code removed. **Part 2**: replacing it — evaluated
2026-08-22 and shelved. **Part 3**: un-shelved and built on 2026-08-23, after
four of Part 2's unknowns turned out to be answered. **Nothing in Part 3 has
been booted.**

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

# Part 2 — Replacing it (evaluated 2026-08-22, superseded by Part 3)

> Kept as the record of what was known before the ROCKNIX image and this unit's
> own SPL were read. Part 3 corrects it in four places, all marked there.

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

# Part 3 — Building it (2026-08-23, unbooted)

`./build-uboot.sh` produces a mainline U-Boot FIT; `MY355_UBOOT=mainline
./build-image.sh` puts it on the card in place of the vendor chain. The default
stays `vendor`, because the released artifact is not the place to test a
bootloader nobody has booted.

> **Provenance.** Everything in this part is *inferred* — from the U-Boot
> sources, from ROCKNIX's shipped binary, and from this unit's own `mtd5`. No
> card built this way has been powered on. The measurements it is aimed at are
> in [boot budget](01-boot-budget.md); none of them have moved yet.

## What changed the decision

Part 2 shelved this on the display blocker with three other unknowns behind it.
The display blocker stands. The other three do not.

**The vendor SPL does not check signatures — only hashes.** Part 2 noted the
vendor FIT carries `algo = "sha256,rsa2048"` and that re-signing is impossible,
which would have ended this if the SPL enforced it. It does not. Strings in this
unit's `mtd5` carry the whole hash path (`Can't get hash algo property`,
`Bad hash value`, `sha256`) and, decisively, the message

```
Verified-boot requires CONFIG_SPL_FIT_SIGNATURE enabled
```

which exists precisely to report that the OTP verified-boot flag is set on a
build that cannot honour it. `## Verified-boot: %d` reads that flag. So the FIT
we write has to carry correct per-image sha256 and nothing more —
`tools/mkfit.py` computes them and re-checks them after writing.

**ROCKNIX ships mainline U-Boot for this SoC, with a Rockchip BL31.** Their
`u-boot.itb`, read out of the RK3566 image at sector 16384, is **U-Boot 2026.01**
built from `quartz64-a-rk3566_defconfig` — 894 288 bytes, `fdt-rockchip/rk3566-quartz64-a`
— and its `atf-1` is **rkbin `bl31-v1.45`** (`v2.3-896`, built Mar 2025), not
mainline TF-A. That matters more than the U-Boot half: the vendor 5.10 BSP
kernel reaches BL31 for DMC and DDR DVFS through Rockchip SIP calls that
mainline TF-A does not implement. Two independent RK3566 handheld distributions
land on the same base, so it is a code path that already runs on this silicon.

**quartz64-a's control device tree is accidentally correct for the Flip's SD
slot.** Resolving the phandles in the DTB inside that `.itb`, `mmc@fe2b0000`
carries:

| | quartz64-a | `rk3566-miyoo-flip.dts` |
|---|---|---|
| `vmmc-supply` | `regulator-fixed`, gpio0 pin 5, active low | `vcc_sd`, `gpio0 RK_PA5 GPIO_ACTIVE_LOW` (`SDMMC_PWREN_L`) |
| `vqmmc-supply` | RK817 `LDO_REG5` `vccio_sd`, 1.8–3.3 V | the same rail |
| `cd-gpios` | gpio0 pin 4, active low | `sdmmc0_det` — gpio0 pin 4 |
| speed | `sd-uhs-sdr104`, 150 MHz | `sd-uhs-sdr50/sdr104`, 150 MHz |

Pine64 wired the SD rails the way Miyoo did. So mainline U-Boot binds a real
`vqmmc` regulator it can drop to 1.8 V and declares SDR104 — which is what the
vendor 2017.09 binary provably cannot do (Part 1: its 10.9 MB/s is **not** a UHS
fallback). Declaring SDR104 is not achieving it, but for the first time the
machinery is present and correctly wired, so the read half of the budget is in
play alongside the initialisation half.

**The Miyoo Flip fork of ROCKNIX has no U-Boot patches.** Checked twice, because
it is the obvious place to look for an SD-voltage or panel fix: the
`u-boot-Specific` package carries two patches, one adding
`CONFIG_ROCKCHIP_RK8XX_DISABLE_BOOT_ON_POWERON` and one setting an SPL boot
order, neither Flip-specific; and a diff of the `flip` branch against its
upstream merge-base across every u-boot and bootloader path changes one line,
which is the WiFi driver list. Every Flip-specific thing in that tree is
kernel-side — `rk3566-miyoo-flip.dts`, the quirks scripts, the joypad and
RTL8733BU patches.

**The display blocker is unchanged.** v2026.01's `drivers/video/rockchip/` still
stops at rk3399 and `vop2` appears nowhere under `drivers/`. Grepping ROCKNIX's
shipped binary finds no VOP or DSI driver strings at all — the only match is
`do not support this vop freq`, which is the *clock* driver. The Flip DTS does
carry a fully reverse-engineered panel (`rocknix,generic-dsi`, FT8006M 640x480
2-lane, DCS init sequence inline, including the same `seq=11 wait=250` /
`seq=29 wait=32` that Part 1 measured in the vendor tree) — but that is consumed
by a ROCKNIX *kernel* driver, and there is no controller in U-Boot for it to sit
on. So: **the mainline path draws no boot logo.** The panel stays dark until the
kernel takes the display.

## What the card carries

The GPT is unchanged — same partitions, same sectors, so the same
[SD boot](02-sd-boot.md) mechanism finds `uboot` by name.

| partition | vendor path | mainline path |
|---|---|---|
| `uboot` @ 16384 | stock 2017.09 FIT, verbatim | our U-Boot + the **vendor's** BL31, OP-TEE and control FDT |
| `boot` @ 32768 | vendor Android boot image, DTB rewritten | a 512-byte header, then a FIT of kernel + DTB |

## The `uboot` FIT

`tools/mkfit.py uboot` takes the vendor FIT apart and puts it back together with
exactly one image replaced:

```
uboot    626 984  @ 0x001000    ours, load 0x00a00000
atf-1    167 936  @ 0x09a200    vendor, byte-for-byte
atf-2..6                        vendor, byte-for-byte
optee    461 216                vendor, byte-for-byte
fdt       14 360                vendor, byte-for-byte
```

Structure, image order, `data-position` layout, `configurations/conf` with
`firmware = "atf-1"` and the same `loadables` — all mirror the vendor's, so the
SPL sees the shape it already loads. The signature node is dropped; per the
evidence above, nothing reads it.

**Keeping the vendor's secure world is the point, not a shortcut.** The DDR blob
in `mtd5` is paired with the unit, BL31 sits behind it, and the BSP kernel talks
to BL31 through Rockchip SIP calls. Reusing rkbin v1.45 the way ROCKNIX does
would have been defensible; reusing *this unit's own* BL31 makes U-Boot the only
variable the change introduces, and needs no new vendor download. It also makes
the `rockchip-dmc` check from [SD boot](02-sd-boot.md) — four FSPs, no
`loader&trust unmatch!!!` — a formality rather than the first thing to look at.

`CONFIG_TEXT_BASE` is set to **0x00a00000**, the vendor's U-Boot load address,
not mainline's 0x00800000. The SPL reads each FIT image straight from the card to
its `load`, so this is the one address on this device already known to work.

## The `boot` FIT, and how U-Boot finds it

No filesystem and no scan. `CONFIG_BOOTCOMMAND` is:

```
mmc dev 1; mmc read 0c000000 8000 1; setexpr.l fitsz *c000008;
mmc read 0a000000 8001 ${fitsz}; bootm 0a000000
```

Sector `0x8000` is a 512-byte header — `MY355FIT`, then the FIT's sector count
as a little-endian `u32` at offset 8 — so the kernel can change size without
rebuilding U-Boot. `setexpr.l` reads that count back (`hextoul` on the address,
`u32` little-endian at it), and the second `mmc read` fetches exactly that many
sectors. `mmc dev 1` is the right-hand slot: `rk356x-u-boot.dtsi` aliases
`mmc0 = &sdhci` (the absent eMMC) and `mmc1 = &sdmmc0`.

The DRAM map lives in one place, `tools/mkfit.py`, and `build-uboot.sh` builds
the bootcmd from it — a silent overlap between where the compressed payload sits
and where the kernel decompresses is a hang with no console to report it:

| | |
|---|---|
| `0x02000000` | the kernel, decompressed — 2 MiB-aligned, per the Image header's `flags = 0xa` |
| `0x0a000000` | the boot FIT as read off the card (**not** 0x00a00000, where U-Boot itself loads) |
| `0x0c000000` | its header sector |

`mkfit.py` asserts the kernel's `image_size` — 37 289 984 bytes, the BSS-inclusive
extent from the arm64 header, not the 36 647 424 on disk — fits below the FIT.

The command line still rides in the device tree, not in U-Boot's environment.
`fdt_chosen()` rewrites `/chosen/bootargs` only when the `bootargs` variable is
set, and this build leaves it unset, so the patched `rk-kernel.dtb` is what the
kernel gets. Repointing `root=` for an A/B slot stays a rebuild of this FIT
alone.

**The `.hdmi` device tree does not come along.** The resource image carries
`rk-kernel.dtb` *and* `rk-kernel.dtb.hdmi`, and it is the vendor U-Boot that
picks between them on `g_miyoo_use_hdmi` (Part 1). Mainline knows nothing about
that global, so the boot FIT carries `rk-kernel.dtb` only — the tree BaseOS
boots today anyway. What is lost is the vendor's "booted with HDMI attached"
variant, not HDMI itself.

**zstd is reachable here, and only here.** The vendor U-Boot sniffs the Android
payload for a magic it knows and has no zstd case to add; a FIT declares its
compression. `CONFIG_ZSTD=y` and the kernel stores at **10 836 333 bytes against
gzip's 12 991 358** — 2.16 MB less to read. (An earlier reading of ROCKNIX's
binary took the string `zstd compressed` as proof their build supports it. It is
not: that string is `genimg_get_comp_name`'s name table, present whether or not
the decompressor is linked in. `quartz64-a-rk3566_defconfig` does *not* set
`CONFIG_ZSTD`; ours does.)

## The build

`build-uboot.sh` fetches U-Boot v2026.01 by pinned sha256, builds it in Docker
against `quartz64-a-rk3566_defconfig` merged with `tools/uboot/my355.config`,
and hands `u-boot.bin` to `mkfit.py`. `SOURCE_DATE_EPOCH=0`, so the same inputs
give the same FIT and "did the bootloader change?" is a checksum question.

The fragment turns off `BOOTSTD` and the whole `bootflow scan` machinery, EFI,
PCIe, NVMe, SCSI/AHCI, USB, networking, the SFC, and the SDHCI driver for an
eMMC this board does not populate; sets `CONFIG_BOOTDELAY=-2` (no delay *and* no
key check — the stock value of 2 is two seconds spent listening to a UART nobody
has attached); and enables `CMD_SETEXPR` and `ZSTD`. Result: **626 984 bytes
against ROCKNIX's 894 288.**

Kconfig can quietly drop a fragment line — `default y`, a `select`, or a `choice`
whose members are not unset but replaced, which is how `CONFIG_NET` first
survived. None of that is visible in a stripped binary and this device has no
console to notice a U-Boot that still waits two seconds, so the build **asserts
every line of the fragment survived `make olddefconfig`** and refuses otherwise.
`build-image.sh` then re-checks that the FIT on disk is the one that build
produced and that it was built for the sector the card actually uses.

## What is unverified

Everything that matters, and in roughly this order:

1. **That the Miyoo SPL loads a FIT we wrote.** The hash evidence says it should.
   If it does not, the SPL walks on to the SPI NAND and stock comes up — the
   failure is safe, but it is also silent.
2. **That mainline U-Boot's own initialisation is cheaper than 1.21 s.** This is
   the entire premise and it has never been measured on this device.
3. **That the SD read gets faster.** The wiring is right; whether the 1.8 V
   switch succeeds on Miyoo's board is empirical.
4. **That the vendor BSP kernel is happy under a mainline BL33.** BL31 and OP-TEE
   are the vendor's, which is most of the risk retired, but not all of it.
5. **That `bootm` hands off correctly** — FIT `os = "linux"`, `type = "kernel"`,
   arm64 `Image` at a 2 MiB-aligned load, the vendor DTB relocated by U-Boot.

A U-Boot that dies early and one that never started are indistinguishable here.
The mitigations are that the card is the only thing written — no NAND — and that
reverting is a re-flash. `CONFIG_BAUDRATE=1500000` on UART2 is kept, so a unit
with the case open gets the whole story.

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
