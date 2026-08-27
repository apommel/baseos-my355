# BaseOS for the Miyoo Flip

A minimal Linux that boots the **Miyoo Flip** (Rockchip RK3566,
`MIYOO RK3566 355 V10 Board`, NextUI platform id `my355`) as fast as the hardware
allows, then hands off to a frontend. It has no interface of its own.

The vendor kernel, U-Boot and BL31 stay **byte-for-byte**; only the userland is
replaced, with a BusyBox init over a measured harvest of the stock glibc stack. The
one change to internal NAND is a 2 MiB preloader patch making the SPL try the SD card
first — stock still boots when no BaseOS card is present.

## Where the time goes

Both systems measured on hardware over adb, 2026-08-23, one cold boot each with the
USB cable unplugged at power-on:

| | stock | BaseOS | |
|---|---|---|---|
| power-on → frontend hand-off | 15.79 s | **4.98 s** | −10.81 s |
| power-on → NextUI's first frame | 31.50 s | **6.87 s** | −24.63 s |

It boots from SD faster than stock boots from internal NAND.

## Building

macOS with unprivileged Alpine containers (Docker or OrbStack) — no sudo, no loop
mounts. Steps running AArch64 binaries pin `linux/arm64`, the rest the host arch.

A card needs three vendor files: U-Boot, the Android boot image, and the harvested
subset of the stock rootfs BaseOS links against. Restore them from the bundle:

```sh
./fetch-prepared.sh
./build-all.sh
```

or derive them from a dump of your own unit's SPI NAND — byte-identical artifacts,
same hashes:

```sh
./prepare-stock.sh ~/Development/miyoo-flip-nand-backup
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
[docs/03-nand-backup-and-recovery.md](docs/03-nand-backup-and-recovery.md);
flashing and the preloader are in [docs/02-sd-boot.md](docs/02-sd-boot.md) and
[docs/06-card-image-build.md](docs/06-card-image-build.md).

## Layout

```
fetch-prepared.sh   published bundle → work/my355/prepared/
prepare-stock.sh    NAND backup      → the same three files
cache-pack.sh       work/my355/prepared/ → a bundle to publish
build-all.sh        rootfs → image → the release .img.zip and .bosupd
build-rootfs.sh     harvest + overlay/ + BusyBox → rootfs.tar
build-image.sh      prepared + rootfs → baseos-my355.img
build-update.sh     image → baseos-my355-<version>.bosupd, the A/B update payload
tests/              offline tests — card expansion, A/B slots, updates
overlay/            init, inittab, rcS, the frontend session — what makes it ours
manifest/           the harvest allowlist, verified closed at prepare time
tools/              GPT, Android boot image, preloader and bootlogo surgery
src/                fbsplash (the panel is this device's only output), the GPT tools
docs/               how it works and why — start at docs/README.md
upstream-h700/      parked H700 code, not built here (see upstream-h700/PARKED.md)
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
