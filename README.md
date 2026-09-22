# BaseOS for the Miyoo Flip

A minimal Linux that boots the **Miyoo Flip** (Rockchip RK3566,
`MIYOO RK3566 355 V10 Board`, NextUI platform id `my355`) as fast as the hardware
allows, then hands off to a frontend. It has no interface of its own.

The vendor kernel, BL31 and OP-TEE stay **byte-for-byte** — the kernel is
stored compressed on the card, and the build asserts it decompresses to the
vendor image. U-Boot proper is mainline, built from source, and the userland is
replaced, with a BusyBox init over a measured harvest of the stock glibc stack.
The one change to internal NAND is a 2 MiB preloader patch making the SPL try the
SD card first — stock still boots when no BaseOS card is present.

## Startup time

BaseOS hands off to the frontend **1.94 s** after power-on, and NextUI shows its
first frame at **2.93–2.98 s**. Stock takes 15.79 s and 31.50 s.

| power-on → | stock | BaseOS 0.6.0 | **BaseOS 0.7.0** |
|---|---|---|---|
| the kernel's first line | 4.30 s | 2.85 s | **0.99 s** |
| frontend hand-off | 15.79 s | 3.73 s | **1.94 s** |
| `nextui.elf` starts | — | 4.19–4.23 s | **2.40–2.42 s** |
| NextUI's first frame | 31.50 s | 5.74 s | **2.93–2.98 s** |
| boot logo on the panel | — | ~1.0 s | 2.00 s |

0.7.0 figures are warm reboots, whose U-Boot timings match cold boots; the first
frame was last measured one step before the final U-Boot changes, which took
~40 ms more off.

- **Vendor userland replaced by a BusyBox init**, deleting 9.9 s of stock boot
  scripts.
- **Kernel stored compressed: 1.86 s.** U-Boot reads ~12 MiB off the card instead
  of 34.9 MiB.
- **SD bus raised to SDR104 (0.2.0): 1.06 s.** The vendor device tree held the
  boot slot at 50 MHz; reads go from 22 to 63 MB/s, at boot and after.
- **Kernel init steps skipped (0.6.0): 0.71 s.** Three initcalls nothing uses,
  halving the kernel's own initialisation.
- **Mainline U-Boot (0.7.0): 1.8 s.** Built from source in place of the vendor
  2017.09, it hands off at 0.94 s: data cache on before relocation, the SD card
  at the 50 MHz it claimed, the GPT held in the block cache, and a zstd kernel
  decompressed at 1800 MHz ([docs/uboot.md](docs/uboot.md)).
- **Vendor libraries on the boot card's ext4**, not the squashfs in SPI NAND.
  NextUI's `launch.sh` loads them in 0.89 s against 12.45 s on stock.

Mainline U-Boot has no display driver for this SoC, so the boot logo is drawn by
`rcS` and reaches the panel at 2.00 s rather than ~1.0 s. What the vendor
U-Boot did for the kernel is redone here: the battery gauge's bookkeeping, and
the charge LED while charging off; its low-battery guard and charge screen are
gone. `MY355_UBOOT=vendor` still builds the 0.6.0 path. Where the rest goes, and
what is left to try, is in [docs/boot-time.md](docs/boot-time.md).

## New in 0.7.0

- **Mainline U-Boot**, above: 1.8 s faster to the frontend.
- **HDMI alongside the panel**, with hot-plug and hot-unplug. Stock disables the
  panel to use a TV and reboots to switch.
- **The charge LED stays lit after a shutdown with the charger in**, until
  the battery is full.
- **The boot card no longer drops out after a suspend**, and adb reconnects
  after one.
- **A crash leaves a record**: the kernel log of a boot that panicked or hung is
  kept in `/data/pstore/`.
- **No more 0.3 s WiFi stall** on about half the boots, on either U-Boot.

## Building

macOS or Linux, x86_64 or ARM, with unprivileged Alpine containers (Docker or
OrbStack) — no sudo, no loop mounts. Steps running AArch64 binaries pin
`linux/arm64`, the rest the host arch. On an x86_64 host the AArch64 steps run
under QEMU: Docker Desktop and OrbStack register the binfmt handlers themselves,
a plain Docker Engine needs them installed once —
`docker run --privileged --rm tonistiigi/binfmt --install arm64`.

A card needs three vendor files: the U-Boot FIT (for its BL31 and OP-TEE), the
Android boot image (for its kernel and device tree), and the harvested subset of
the stock rootfs BaseOS links against. Restore them from the bundle:

```sh
./fetch-prepared.sh
./build-all.sh
```

or derive them from a dump of your own unit's SPI NAND — byte-identical artifacts,
same hashes:

```sh
./prepare-stock.sh ~/my-flip-nand-backup
./build-all.sh
```

Either way you get `baseos-my355-<version>.img.zip`. The bundle is a cache, not a
second source of truth: `manifest/prepared/source.json` holds each artifact's size
and SHA-256, travels in git rather than inside the download, and every build checks
against it.

Step-by-step instructions for users are in [INSTALL.md](INSTALL.md).

**The card installs the preloader itself.** On first boot with a stock device, the
stock OS picks up `miyoo355_fw.img` from the card, patches your own `mtd5` and reboots
into BaseOS — about four seconds, no host needed. It refuses if the preloader is
already patched or is GammaLoader's, and copies the original to the card before
erasing.

**Take a NAND backup regardless.** Nothing here ships a preloader binary: the installer
and `tools/mkpreloader.py` both patch the copy already on your device. A backup is how
you recover from a bad NAND write. See
[docs/recovery.md](docs/recovery.md);
flashing and the preloader are in [docs/boot-chain.md](docs/boot-chain.md) and
[docs/card.md](docs/card.md).

## Layout

```
fetch-prepared.sh   published bundle → work/my355/prepared/
prepare-stock.sh    NAND backup      → the same four files
cache-pack.sh       work/my355/prepared/ → a bundle to publish
build-all.sh        U-Boot → rootfs → image → the release .img.zip and .bosupd
build-uboot.sh      mainline U-Boot + tools/uboot/ patches → uboot-mainline.itb
build-rootfs.sh     harvest + overlay/ + BusyBox → rootfs.tar
build-image.sh      prepared + rootfs → baseos-my355.img
build-update.sh     image → baseos-my355-<version>.bosupd, the A/B update payload
flash-card.sh       image → an SD card, on macOS; refuses anything but removable media
tests/              offline tests — card expansion, A/B slots, updates, preloader, harvest, fuel gauge
overlay/            init, inittab, rcS, the frontend session — what makes it ours
manifest/           the harvest allowlist, verified closed at prepare time
tools/              GPT, FIT, Android boot image, preloader and bootlogo surgery;
                    tools/uboot/ holds the U-Boot patches, config and control tree
src/                fbsplash (the panel is this device's only output), the GPT tools,
                    rebootmode
docs/               how it works and why — start at docs/README.md
```

## Relationship to BaseOS for H700

Forked from [BaseOS](https://github.com/pvaibhav/BaseOS) for Allwinner H700
handhelds, sharing its philosophy: keep the vendor kernel, delete the vendor
userland, measure everything. The hardware does not overlap — different SoC vendor,
different first stage, boot chain in SPI NAND rather than on the card, a Rockchip
Android boot image rather than an inherited GPT. Boot chain, image format and build
pipeline here are independent; `src/fbsplash.c`, the artwork and the
container-platform helper are shared, and the card-expansion and A/B update
machinery is adapted. See [NOTICE](NOTICE).
