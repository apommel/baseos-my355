# BaseOS for the Miyoo Flip

A minimal Linux that boots the **Miyoo Flip** (Rockchip RK3566,
`MIYOO RK3566 355 V10 Board`, NextUI platform id `my355`) as fast as the hardware
allows and hands off to a frontend. BaseOS has no interface of its own.

The vendor kernel, U-Boot and BL31 are kept **byte-for-byte**; only the userland is
replaced, with a BusyBox init over a measured harvest of the stock glibc stack. The
one change to internal NAND is a 2 MiB preloader patch that makes the SPL look at the
SD card first — stock still boots when no BaseOS card is present.

## Where the time goes

Both systems measured on hardware over adb, 2026-08-23, one cold boot each with the
USB cable unplugged at power-on:

| | stock | BaseOS | |
|---|---|---|---|
| power-on → frontend hand-off | 15.79 s | **5.05 s** | −10.74 s |
| power-on → NextUI's first frame | 31.50 s | **7.98 s** | −23.52 s |

It boots from SD faster than stock boots from internal NAND.

Read the second row with a caveat that the boot budget spells out: 11.6 s of that
23.5 s is NextUI's own `launch.sh` taking 12.45 s on stock against 0.88 s here, which
is a script BaseOS neither owns nor changed and cannot yet explain. **The honest
BaseOS claim is the first row.** The full breakdown, including what each phase costs
and which levers are left, is in [docs/01-boot-budget.md](docs/01-boot-budget.md).

## Building

Builds run on macOS using unprivileged Alpine containers (Docker or OrbStack) — no
sudo, no loop mounts. Steps that execute AArch64 device binaries pin `linux/arm64`;
the rest pin the host architecture.

You need a **NAND backup of your own unit** (see
[docs/03-nand-backup-and-recovery.md](docs/03-nand-backup-and-recovery.md)). Nothing
vendor-derived is redistributed here — every build starts from your dump.

```sh
./prepare-stock.sh ~/Development/miyoo-flip-nand-backup
./build-rootfs.sh
./build-image.sh
```

That produces `work/my355/baseos-my355.img`. Flashing, the preloader patch and the
recovery path are in [docs/02-sd-boot.md](docs/02-sd-boot.md) and
[docs/06-card-image-build.md](docs/06-card-image-build.md).

## Layout

```
prepare-stock.sh    NAND backup  → work/my355/prepared/
build-rootfs.sh     harvest + overlay/ + BusyBox → rootfs.tar
build-image.sh      prepared + rootfs → baseos-my355.img
overlay/            init, inittab, rcS, the frontend session — what makes it ours
manifest/           the harvest allowlist, verified closed at prepare time
tools/              GPT, Android boot image, preloader and bootlogo surgery
src/fbsplash.c      the panel is this device's only output
docs/               how it works and why — start at docs/README.md
upstream-h700/      parked H700 code, not built here (see upstream-h700/PARKED.md)
```

## Relationship to BaseOS for H700

This started as a fork of [BaseOS](https://github.com/pvaibhav/BaseOS) for Allwinner
H700 handhelds and shares its philosophy — keep the vendor kernel, delete the vendor
userland, measure everything. The hardware does not overlap: different SoC vendor,
different first stage, boot chain in SPI NAND rather than on the card, a Rockchip
Android boot image rather than an inherited GPT. The boot chain, image format and
build pipeline here are independent; `src/fbsplash.c`, the artwork and the
container-platform helper are shared, and the docs cite the H700 ones throughout for
comparison. See [NOTICE](NOTICE).
