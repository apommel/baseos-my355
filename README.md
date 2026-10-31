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
- **Longer battery life.** With WiFi and Bluetooth off the radio chip is powered
  down, and the memory no longer runs at full speed all the time.
- **Read-only rootfs.** Pulling the battery or a crash won't corrupt the system
  or the cards.
- **The essentials work:** HDMI, WiFi, Bluetooth audio, SSH and adb.

## Startup time

| power-on → | stock | **BaseOS** |
|---|---|---|
| the kernel's first line | 4.30 s | **0.59 s** |
| frontend starts | 15.79 s | **1.27–1.30 s** |
| `nextui.elf` starts | — | **2.21–2.27 s** |
| NextUI's first frame | 31.50 s | **2.57–2.67 s** |

Stock measured with USB unplugged; BaseOS over warm reboots by adb, on the
default `gpu=mali`. With `gpu=panfrost` the first frame is at 2.34–2.39 s.

Where the time is saved:

- **Stock boot scripts are replaced** by a small BusyBox init, saving 9.9 s.
- **A mainline U-Boot**, built from source, starts the kernel at 0.59 s
  ([docs/uboot.md](docs/uboot.md)).
- **The kernel is built for this board and stored compressed**, so about
  6.6 MiB is read from the card instead of 26 MiB.
- **The SD card runs at full speed**: 64 MB/s instead of 22 MB/s.
- **The kernel is built for this device**: no framebuffer console, and the
  panel's power-up waits shortened.
- **Vendor libraries load from the SD card** instead of the slower internal storage.

The vendor-kernel measurements behind most of this are in
[docs/boot-time.md](docs/boot-time.md).

## How it works

U-Boot and Linux are mainline, built from source; the vendor's BL31 and OP-TEE
are kept unchanged. The vendor userland is replaced by a BusyBox init, plus the
parts of the stock libraries that frontends need. Stock-built frontends run
unmodified: the kernel presents the interfaces they expect from the vendor
kernel ([docs/mainline-compat.md](docs/mainline-compat.md)). The GPU driver is
Rockchip's libmali or Mesa's Panfrost, picked in `baseos.conf`.

## Building

Everything is built by [Buildroot](https://buildroot.org), in Docker or OrbStack,
on macOS or Linux. On x86_64 with plain Docker Engine, enable ARM emulation once:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

Then:

```sh
./build.sh
```

This writes `work/images/baseos-my355-<version>.img.zip`, the `.bosupd` update
and `SHA256SUMS`. Two files come from the stock firmware, the vendor U-Boot
and the Bluetooth firmware; the build downloads them, checked by hash.

## Layout

The repository is a Buildroot external tree:

```
build.sh            run the build in Docker
configs/            the Buildroot defconfig
board/my355/        kernel and U-Boot patches and configs, the rootfs overlay,
                    the image scripts, the preloader installer
package/            BaseOS's own packages: libmali, Mesa's Panfrost, the kernel
                    modules, the stock firmware, SDL, src/'s tools
patches/            fixes and hashes for Buildroot's own packages
src/                boot splash and small helper programs
tools/              image and boot chain tools
tests/              offline tests
flash-card.sh       write the image to an SD card (macOS)
docs/               documentation — start at docs/README.md
```

## Relationship to BaseOS for H700

Forked from [BaseOS](https://github.com/pvaibhav/BaseOS) for Allwinner H700
handhelds, with the same approach: replace the vendor userland, keep what
frontends depend on, measure everything. The hardware is different, so the boot chain, image
format and build are separate. The boot splash, artwork and some build helpers are
shared, and the card setup and update system are adapted from it. See [NOTICE](NOTICE).
