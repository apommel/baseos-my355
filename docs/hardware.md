# Hardware

The device BaseOS runs on: Miyoo Flip (`MIYOO RK3566 355 V10 Board`), NextUI
platform id **`my355`**. Everything here was read off a running stock unit.

| | |
|---|---|
| SoC | Rockchip RK3566, 4× Cortex-A55, Mali-G52 2EE |
| RAM | 1006 MiB LPDDR4 (`Size=1024MB`, 16 MiB CMA) |
| Storage | 128 MB SPI NAND (Winbond, via SFC) + 2× microSD |
| Stock OS | Buildroot 2021.11, glibc 2.36, BusyBox 1.36.0, **squashfs root on `mtdblock3`** |
| Stock kernel | 5.10.160 `#152 SMP Mon May 26 14:30:16 CST 2025` (Rockchip BSP) |
| Stock U-Boot | 2017.09 (Jun 27 2025 - 23:33:02 +0800) |
| Stock SPL | 2017.09 (Dec 12 2024 - 10:17:54), DDR blob `V1.18 f366f69a7d` |
| Frontend | NextUI `my355` (stock runs it from the **right** slot; BaseOS takes that slot and reads the frontend from the left — [rootfs](rootfs.md)) |

> The device-level reverse-engineering wiki lives in
> [Miyoo-Flip-Mainline-Linux-Reverse-Engineering](https://github.com/Zetarancio/Miyoo-Flip-Mainline-Linux-Reverse-Engineering).
> This file records only what bears on porting BaseOS, and **corrects two things**
> that wiki currently states — see [recovery](recovery.md).

---

## The boot chain lives in internal flash

The whole vendor boot chain — preloader, U-Boot, kernel, rootfs — is in internal
SPI NAND, and the root device is baked into the kernel command line:

```
storagemedia=mtd androidboot.storagemedia=mtd rootwait
earlycon=uart8250,mmio32,0xfe660000 console=ttyFIQ0
root=/dev/mtdblock3 rootfstype=squashfs
mtdparts=spi-nand0:0x100000@0x200000(vnvm),0x400000@0x300000(uboot),
         0x2600000@0x700000(boot),0x4000000@0x2d00000(rootfs),0x1260000@0x6d00000(userdata)
```

There is **no writable U-Boot environment** (`Using default environment`), so `root=`
cannot be redirected without rewriting `mtd2`. What BaseOS does instead is
[the boot chain](boot-chain.md): patch the preloader so the SPL tries the card
first, and put a U-Boot and a boot image on the card for it to find.

### MTD layout (from `/sys/class/mtd/*`)

| dev | name | offset | size | contents |
|---|---|---|---|---|
| `mtd5` | `spl` | `0x0` | 2 MiB | **preloader**: IDB (`RKNS` @ sector 64) + DDR blob + SPL |
| `mtd0` | `vnvm` | `0x200000` | 1 MiB | vendor non-volatile |
| `mtd1` | `uboot` | `0x300000` | 4 MiB | U-Boot FIT (ATF + OP-TEE + U-Boot + FDT) |
| `mtd2` | `boot` | `0x700000` | 38 MiB | Android boot image (kernel + resource/DTB) |
| `mtd3` | `rootfs` | `0x2d00000` | 64 MiB | squashfs (48.8 MiB used) |
| `mtd4` | `userdata` | `0x6d00000` | ~18 MiB | writable |

`mtd5` exposing the preloader at offset 0 is **firmware-dependent**; the RE wiki states
stock does not expose it. On this build it does, and `nanddump`, `nandwrite` and
`flash_erase` are all present in the stock rootfs — so the preloader is readable *and*
writable from a running stock system, no `/dev/mem` hack and no disassembly.

### Kernel config points that matter

Confirmed from `/proc/config.gz`. Between them these are why `rcS` is as short as
it is:

- `CONFIG_DEVTMPFS_MOUNT=y` — the kernel mounts `/dev` itself.
- No initramfs in use: the kernel mounts root directly.
- `ext4`, `vfat`, `squashfs`, `overlay`, `ntfs`, `xfs`, `f2fs`-adjacent all built in.
- `CONFIG_DRM_FBDEV_EMULATION=y` → `/dev/fb0` exists, so `fbsplash` works.
- `CONFIG_KALLSYMS=y`, which is what makes `initcall_blacklist=` work
  ([boot time](boot-time.md)).
- Essentially every driver is built in. Only one module is loaded at runtime
  (`RTL8189FU`, unused). Mali, `rtl8733bu` (WiFi) and the DSI panel are all
  in-kernel, so the rootfs needs almost no module handling.

---

## SD slot mapping — verified

| physical | DT node | kernel alias | boot-capable |
|---|---|---|---|
| right (near power) | `dwmmc@fe2b0000` | `mmc1` → `mmcblk1` | **yes** |
| left (near volume) | `dwmmc@fe2c0000` | `mmc2` → `mmcblk2` | **no** (see [history](history.md)) |
| — | `sdhci@fe310000` | `mmc0` | eMMC, not populated |

Stock's `runmiyoo.sh` binds `/mnt/sdcard` to the right slot only and power-offs with
*"Please use the right SD slot for NextUI"* if a NextUI card is found on the left.

The left slot is also capped at high speed: its pins sit in a fixed 3.3 V I/O
domain, so it cannot do UHS ([boot time](boot-time.md)).

---

## The preloader's SPL boot order

Extracted from the FDT embedded in this unit's `mtd5` (two copies, at file offsets
`0x685d8` and `0xc85d8`; the IDB stores the SPL twice):

```
chosen {
  u-boot,spl-boot-order = "/sdhci@fe310000",        /* eMMC — absent   */
                          "/dwmmc@fe2b0000",        /* SD, right slot  */
                          "/dwmmc@fe2c0000",        /* SD, left slot   */
                          "/nandc@fe330000",        /* raw NAND — absent */
                          "/sfc@fe300000/flash@0";  /* SPI NAND — stock U-Boot */
}
```

**The stock preloader tries both SD slots before internal SPI NAND.** That is the
mechanism a "card present → boot from card, otherwise stock" design would rely on.

> **This differs between firmware builds.** The `preloader.img` checked into the RE
> wiki (SPL built Nov 02 2024) lists only `/dwmmc@fe2b0000` and has no left-slot entry.
> Do not assume a given unit's boot order; read it from that unit's `mtd5`.
