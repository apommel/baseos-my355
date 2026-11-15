# FlipBase for the Miyoo Flip

A modern base OS for the **Miyoo Flip** (Rockchip RK3566, not Miyoo Mini Flip):
mainline Linux and a userland built from source, which boots as fast as the
hardware allows and then starts a frontend such as NextUI or SpruceOS. It has no
interface of its own.

- **Compatible with stock.** Frontends built for the stock firmware run unmodified.
- **More for frontends that target it.** Current libraries, an SDK to build
  against them, and device features stock doesn't have.
- **Lean and fast.** A small userland and a kernel cut to this board; NextUI is
  on screen in under 2.5 s.

FlipBase runs from the SD card and leaves the stock system in place: take the card out
and the Flip boots stock, as before. To install, see [INSTALL.md](INSTALL.md).

## Features

- **Fast boot.** NextUI is on screen about 2.4 s after power-on, instead of 31.5 s.
- **Stock frontends run unmodified.** The kernel presents the vendor kernel's
  interfaces, and the rootfs keeps the libraries stock-built frontends link.
- **A modern platform to target.** GCC 15, glibc 2.44, SDL3 and its add-ons,
  Vulkan, and a choice of GPU driver: Mesa's Panfrost or Rockchip's libmali.
  The [SDK](docs/sdk.md) builds against exactly what runs on the device.
- **Stock system untouched.** The only change to internal storage is a small patch
  that makes the Flip boot from the SD card first. The original is backed up.
- **Easy install.** Put the image on a card and boot: it sets itself up.
- **Safe updates.** If a new version fails to start, the Flip goes back to the
  previous one. ROMs, saves and settings are kept.
- **Longer battery life.** The radio chip is powered down with WiFi and Bluetooth
  off, the memory clock scales with load, and sleep draws as little as stock.
- **Read-only rootfs.** Pulling the battery or a crash won't corrupt the system
  or the cards.
- **The essentials work:** HDMI, WiFi, Bluetooth audio, USB audio, SSH and adb.

## Startup time

| power-on → | stock | **FlipBase** |
|---|---|---|
| the kernel's first line | 4.30 s | **0.59 s** |
| frontend starts | 15.79 s | **1.31–1.34 s** |
| `nextui.elf` starts | — | **1.97–2.04 s** |
| NextUI's first frame | 31.50 s | **2.34–2.39 s** |

Stock measured with USB unplugged; FlipBase over warm reboots by adb, on the
default `gpu=panfrost`. With `gpu=mali` the first frame is at 2.57–2.67 s.

Where the time is saved:

- **Stock boot scripts are replaced** by a small BusyBox init, saving 9.9 s.
- **A mainline U-Boot**, built from source, starts the kernel at 0.59 s
  ([docs/uboot.md](docs/uboot.md)).
- **The kernel is built for this device and stored compressed**: about 6.6 MiB
  is read from the card instead of 26 MiB, with no framebuffer console and
  shorter panel power-up waits.
- **The SD card runs at full speed**: 64 MB/s instead of 22 MB/s.
- **Vendor libraries load from the SD card** instead of the slower internal storage.

Details are in [docs/boot-time.md](docs/boot-time.md).

## How it works

U-Boot and Linux are mainline, built from source; the vendor's BL31 and OP-TEE
are kept unchanged. The vendor userland is replaced by a BusyBox init and a
Buildroot rootfs that keeps the library interface stock-built frontends use
([docs/rootfs-interface.md](docs/rootfs-interface.md)). The kernel presents the
interfaces they expect from the vendor kernel
([docs/mainline-compat.md](docs/mainline-compat.md)), and adds its own, such as
turbo buttons and an optional keyboard device in the gamepad driver. Settings
are in `flipbase.conf` on the card ([INSTALL.md](INSTALL.md#settings)).

## Building

Everything is built by [Buildroot](https://buildroot.org), in Docker or OrbStack,
on macOS or Linux. On x86_64 with plain Docker Engine, enable ARM emulation once:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

Then:

```sh
./build.sh          # the image and update
./build.sh sdk      # the SDK
```

This writes `work/images/flipbase-my355-<version>.img.zip`, the `.bosupd` update
and `SHA256SUMS`. Two files come from the stock firmware, the vendor U-Boot
and the Bluetooth firmware; the build downloads them, checked by hash. More in
[CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

The repository is a Buildroot external tree:

```
build.sh            run the build in Docker
configs/            the Buildroot defconfig
board/my355/        kernel and U-Boot patches and configs, the rootfs overlay,
                    the image scripts, the preloader installer
package/            FlipBase's own packages: libmali, Mesa's Panfrost, SDL, the
                    kernel modules, the stock firmware, src/'s tools
patches/            fixes for Buildroot's own packages
src/                boot splash and small helper programs
tools/              image, boot chain and ABI scan tools
tests/              offline tests
flash-card.sh       write the image to an SD card (macOS)
docs/               documentation — start at docs/README.md
```

## Acknowledgements

The move to mainline Linux was made possible by **Zetarancio's**
[Miyoo Flip Mainline Linux Reverse Engineering](https://github.com/Zetarancio/Miyoo-Flip-Mainline-Linux-Reverse-Engineering)
work. Its hardware findings, device tree and drivers are the base FlipBase's
kernel builds on, and several of its patches are carried here under Zetarancio's
name. Some pieces also come from [ROCKNIX](https://rocknix.org). See [NOTICE](NOTICE).

## Relationship to BaseOS for H700

FlipBase is inspired by, and forked from, [BaseOS](https://github.com/pvaibhav/BaseOS)
for Allwinner H700 handhelds. It was called BaseOS until it moved to mainline
Linux; the new name keeps the lineage and marks it as an independent project.
Same approach: replace the vendor userland, keep what frontends depend on,
measure everything. The hardware is different, so the boot chain, image format
and build are separate. The boot splash, artwork and some build helpers are
shared, and the card setup and update system are adapted from it.
