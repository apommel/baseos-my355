# BaseOS for the Miyoo Flip

A minimal Linux that boots the **Miyoo Flip** (Rockchip RK3566,
`MIYOO RK3566 355 V10 Board`, NextUI platform id `my355`) as fast as the hardware
allows, then hands off to a frontend such as NextUI. It has no interface of its own.

BaseOS runs from the SD card and leaves the stock system in place: take the card out
and the Flip boots stock, exactly as before. To install, see [INSTALL.md](INSTALL.md).

## Features

- **Boots in under 2 seconds.** NextUI shows its first frame about 3 s after
  power-on, against 31.5 s on stock.
- **Installs itself from the card.** On first boot the card patches 2 MiB of the
  preloader so the Flip looks at the SD card first, after backing up the original.
  Nothing else in internal storage is touched.
- **One or two cards.** NextUI can live on a second card in the left-hand slot,
  which can be swapped while running, or share the BaseOS card. An existing NextUI
  card works as is, and a fresh NextUI release installs itself on first boot.
- **HDMI alongside the panel**, with hot-plug and hot-unplug — no reboot to switch.
- **WiFi, Bluetooth audio, SSH and adb over USB**, with network time. Hostname and
  SSH password are set in `baseos.conf` on the card.
- **Safe updates.** Drop a `.bosupd` file on either card: the update is written
  to a spare slot, and the Flip falls back to the previous version by itself if the
  new one does not start. ROMs, saves and settings are left alone.
- **Built to survive pulled power.** The system is mounted read-only, the cards'
  FAT volumes are repaired at boot if they were not cleanly unmounted, and the
  power key shuts down cleanly even without a frontend running.
- **Battery care.** The charge LED stays lit while charging off, a flat battery is
  refused rather than booted, and the battery gauge's bookkeeping is kept.
- **A crash leaves a record**: the kernel log of a boot that panicked or hung is
  kept in `/data/pstore/`.

## Startup time

| power-on → | stock | **BaseOS** |
|---|---|---|
| the kernel's first line | 4.30 s | **0.99 s** |
| frontend hand-off | 15.79 s | **1.99 s** |
| `nextui.elf` starts | — | **2.40–2.42 s** |
| NextUI's first frame | 31.50 s | **2.93–2.98 s** |

Measured with USB unplugged. The boot logo reaches the panel at 2.00 s.

Where the time goes:

- **The vendor userland is replaced by a BusyBox init**, deleting 9.9 s of stock
  boot scripts.
- **A mainline U-Boot**, built from source, hands off to the kernel at 0.94 s:
  data cache on before relocation, the card read at full speed, and a zstd kernel
  decompressed at 1800 MHz ([docs/uboot.md](docs/uboot.md)).
- **The kernel is stored compressed**: about 12 MiB read off the card instead of
  34.9 MiB.
- **The SD bus runs at SDR104.** The vendor device tree held the boot slot at
  50 MHz; reads go from 22 to 63 MB/s, at boot and after.
- **Unused kernel init steps are skipped**, halving the kernel's own
  initialisation.
- **Vendor libraries load from the card's ext4**, not the squashfs in SPI NAND.
  NextUI's `launch.sh` takes 0.89 s against 12.45 s on stock.

The full breakdown, and what is left to try, is in
[docs/boot-time.md](docs/boot-time.md).

## How it works

The vendor kernel, BL31 and OP-TEE stay **byte-for-byte** — the kernel is stored
compressed on the card, and the build asserts it decompresses to the vendor image.
U-Boot proper is mainline, built from source, and the userland is replaced, with a
BusyBox init over a measured harvest of the stock glibc stack. The one change to
internal NAND is the preloader patch making the SPL try the SD card first.

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
tests/              offline tests — card expansion, A/B slots, updates, preloader, harvest, fuel gauge,
                    FAT repair, settings
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
