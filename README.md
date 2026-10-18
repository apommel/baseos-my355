# BaseOS for the Miyoo Flip

A minimal Linux that boots the **Miyoo Flip** (Rockchip RK3566, not Miyoo Mini Flip)
as fast as the hardware allows, then starts a frontend such as NextUI or SpruceOS.
It has no interface of its own.

BaseOS runs from the SD card and leaves the stock system in place: take the card out
and the Flip boots stock, as before. To install, see [INSTALL.md](INSTALL.md).

## Features

- **Fast boot.** NextUI is on screen about 3 s after power-on, instead of 31.5 s.
- **Stock system untouched.** The only change to internal storage is a small patch
  that makes the Flip boot from the SD card first. The original is backed up.
- **Easy install.** Put the image on a card and boot: it sets itself up.
- **Safe updates.** If a new version fails to start, the Flip goes back to the
  previous one. ROMs, saves and settings are kept.
- **Read-only rootfs.** Pulling the battery or a crash won't corrupt the system
  or the cards.
- **The essentials work:** HDMI, WiFi, Bluetooth audio, SSH and adb.

## Startup time

| power-on → | stock | **BaseOS** |
|---|---|---|
| the kernel's first line | 4.30 s | **0.99 s** |
| frontend starts | 15.79 s | **1.99 s** |
| `nextui.elf` starts | — | **2.40–2.42 s** |
| NextUI's first frame | 31.50 s | **2.93–2.98 s** |

Measured with USB unplugged.

Where the time is saved:

- **Stock boot scripts are replaced** by a small BusyBox init, saving 9.9 s.
- **A mainline U-Boot**, built from source, starts the kernel at 0.94 s
  ([docs/uboot.md](docs/uboot.md)).
- **The kernel is stored compressed**, so about 12 MiB is read from the card
  instead of 34.9 MiB.
- **The SD card runs at full speed**: 63 MB/s instead of 22 MB/s.
- **Unused kernel startup steps are skipped**, halving the kernel's own startup.
- **Vendor libraries load from the SD card** instead of the slower internal storage.

Details are in [docs/boot-time.md](docs/boot-time.md).

## How it works

The vendor kernel, BL31 and OP-TEE are kept unchanged. U-Boot is mainline, built
from source. The vendor userland is replaced by a BusyBox init, plus the parts of
the stock libraries that frontends need.

## Building

Should work on macOS or Linux, x86_64 or ARM, using Docker or OrbStack.
On x86_64 with plain Docker Engine (not Docker Desktop or OrbStack), enable ARM
emulation once:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

The build needs three files from the stock firmware. Download them:

```sh
./fetch-prepared.sh
./build-all.sh
```

or extract them from a backup of your own Flip's internal storage (same result):

```sh
./prepare-stock.sh ~/my-flip-nand-backup
./build-all.sh
```

Either way you get `baseos-my355-<version>.img.zip`. Every build checks these files
against the sizes and SHA-256 hashes in `manifest/prepared/source.json`.

## Layout

```
fetch-prepared.sh   download the stock files
prepare-stock.sh    extract the stock files from a NAND backup
cache-pack.sh       package the stock files for publishing
build-all.sh        build everything: the release .img.zip, .bosupd and SHA256SUMS
build-uboot.sh      build U-Boot
build-rootfs.sh     build the root filesystem
build-image.sh      build the SD card image
build-update.sh     build the update file (.bosupd)
flash-card.sh       write the image to an SD card (macOS)
tests/              offline tests
overlay/            init scripts and the frontend launcher
manifest/           list of stock files to keep
tools/              image and boot chain tools; U-Boot patches in tools/uboot/
src/                boot splash and small helper programs
docs/               documentation — start at docs/README.md
```

## Relationship to BaseOS for H700

Forked from [BaseOS](https://github.com/pvaibhav/BaseOS) for Allwinner H700
handhelds, with the same approach: keep the vendor kernel, replace the vendor
userland, measure everything. The hardware is different, so the boot chain, image
format and build are separate. The boot splash, artwork and some build helpers are
shared, and the card setup and update system are adapted from it. See [NOTICE](NOTICE).
