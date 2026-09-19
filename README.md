# BaseOS for the Miyoo Flip

A minimal Linux that boots the **Miyoo Flip** (Rockchip RK3566,
`MIYOO RK3566 355 V10 Board`, NextUI platform id `my355`) as fast as the hardware
allows, then hands off to a frontend. It has no interface of its own.

The vendor kernel, BL31 and OP-TEE stay **byte-for-byte** — the kernel is
stored compressed on the card, and the build asserts it decompresses to the
vendor image. U-Boot proper is mainline, built from source, and the userland is
replaced, with a BusyBox init over a measured harvest of the stock glibc stack. The one change to internal NAND is a 2 MiB preloader patch
making the SPL try the SD card first — stock still boots when no BaseOS card is
present.

## Startup time

BaseOS hands off to the frontend **3.73 s** after power-on, and NextUI shows its
first frame at **5.74 s**. Stock takes 15.79 s and 31.50 s.

| | stock | BaseOS 0.6.0 | |
|---|---|---|---|
| power-on → frontend hand-off | 15.79 s | **3.73 s** | −12.06 s |
| power-on → NextUI's first frame | 31.50 s | **5.74 s** | −25.76 s |

- **Vendor userland replaced by a BusyBox init**, deleting 9.9 s of stock boot
  scripts.
- **Kernel stored gzipped: 1.86 s.** U-Boot reads 11.9 MiB off the card instead
  of 34.9 MiB.
- **SD bus raised to SDR104 (0.2.0): 1.06 s.** The vendor device tree held the
  boot slot at 50 MHz; reads go from 22 to 63 MB/s, at boot and after.
- **Kernel init steps skipped (0.6.0): 0.71 s** Unnecessary kernel init steps were
  skipped, dividing by two kernel initialization time.
- **Vendor libraries on the boot card's ext4**, not the squashfs in SPI NAND.
  NextUI's `launch.sh` loads them in 0.89 s against 12.45 s on stock.

**Mainline U-Boot (after 0.6.0, experimental).** The figures above are 0.6.0,
on the vendor U-Boot. The default build now replaces it with a mainline one:
the kernel prints its first line at 1.17 s instead of 2.85 s, the frontend
hand-off is at 2.10–2.12 s and NextUI's first frame at 3.16–3.19 s. The cost is
a later boot logo, at 2.15 s instead of ~1.0 s, and the vendor U-Boot's
low-battery guard ([docs/uboot.md](docs/uboot.md)). `MY355_UBOOT=vendor` builds
the 0.6.0 path. Where the rest goes, and what is left to try, is in
[docs/boot-time.md](docs/boot-time.md).

## Building

macOS or Linux, x86_64 or ARM, with unprivileged Alpine containers (Docker or
OrbStack) — no sudo, no loop mounts. Steps running AArch64 binaries pin
`linux/arm64`, the rest the host arch. On an x86_64 host the AArch64 steps run
under QEMU: Docker Desktop and OrbStack register the binfmt handlers themselves,
a plain Docker Engine needs them installed once —
`docker run --privileged --rm tonistiigi/binfmt --install arm64`.

A card needs three vendor files: U-Boot, the Android boot image, and the harvested
subset of the stock rootfs BaseOS links against. Restore them from the bundle:

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
build-all.sh        rootfs → image → the release .img.zip and .bosupd
build-rootfs.sh     harvest + overlay/ + BusyBox → rootfs.tar
build-image.sh      prepared + rootfs → baseos-my355.img
build-update.sh     image → baseos-my355-<version>.bosupd, the A/B update payload
flash-card.sh       image → an SD card, on macOS; refuses anything but removable media
tests/              offline tests — card expansion, A/B slots, updates, preloader, harvest
overlay/            init, inittab, rcS, the frontend session — what makes it ours
manifest/           the harvest allowlist, verified closed at prepare time
tools/              GPT, Android boot image, preloader and bootlogo surgery
src/                fbsplash (the panel is this device's only output), the GPT tools
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
