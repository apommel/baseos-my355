# Contributing

## Development environment

macOS or Linux, x86_64 or ARM, with Docker or OrbStack. The build runs in a
`linux/arm64` container, under QEMU on x86_64; a plain Docker Engine needs the
binfmt handlers registered:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

Take a NAND backup even if you never write to it. Making one, and recovering from
a bad preloader write, are in [docs/recovery.md](docs/recovery.md) — read it
before writing anything to `mtd5`, the one region where a mistake costs a MASKROM
recovery.

## The build

`./build.sh` runs Buildroot with this repository as `BR2_EXTERNAL`, and takes
make targets:

```sh
./build.sh                       # everything → work/images/
./build.sh linux-rebuild all     # after editing a kernel patch
./build.sh linux-menuconfig linux-update-defconfig
./build.sh sdk                   # the SDK (docs/sdk.md)
./flash-card.sh diskN            # macOS: the image → an SD card
```

The first build takes a few hours, mostly the toolchain and the host LLVM that
compiles Panfrost's shaders; later ones rebuild what changed. Buildroot does not
track config or patch edits: rebuild the package, as above.

- **Kernel:** Linux from kernel.org, `board/my355/linux/hardware/` (the board on
  mainline) then `stock/` (the stock interface on top), `linux.config`, and the
  device tree, which carries the command line.
- **U-Boot:** `board/my355/uboot/` and `uboot.config`; the boot script is
  `uboot.env`. `post-image.sh` packs it with stock's BL31 and OP-TEE.
- **Stock firmware:** `package/stock-firmware` downloads the published bundle.
  To use your own dump instead, put `uboot.img` (`mtd1`) and a
  `stock-harvest.tar` holding `usr/lib/firmware/rtl8733bu_{fw,config}` (from
  `mtd3`) in a directory, and build with `STOCK_FIRMWARE=<dir> ./build.sh`.
- **Diagnostics:** `./build.sh --diag` builds into its own output directory with
  U-Boot's console saved to the card, a bootstage mark per initcall and per
  card-init step, and probes for the first frame (`baseos-bootinfo timeline`)
  and what the panel shows (`/run/boot-display.log`). Not for release —
  [diagnostics](docs/diagnostics.md).

## Debugging a device that cannot talk

No UART is attached and the kernel has no framebuffer console, so a dead boot
looks like a good one. Do not iterate blind —
[docs/diagnostics.md](docs/diagnostics.md) lists the signals that work, the failure
signatures, and when to open the case and put a wire on `ttyS2` at 1500000 baud.

The decisive trick: put the BaseOS card in the **left** slot. It is not in the SPL
boot order, so the device boots stock from NAND and mounts the card under `/media/`,
where everything the failed boot wrote is readable over adb.

## Measuring the boot

Kernel timestamps are power-on-relative (the bootloader does not reset the arch
counter); `/proc/uptime` is not. Pin the offset — a `jbd2/mmcblk1p*` `starttime`
against its `EXT4-fs … mounted` printk, or an uptime reading echoed into `/dev/kmsg`
— then read the `/run/boot-*` breadcrumbs and `/proc/<pid>/stat` field 22. Worked
examples in [docs/boot-time.md](docs/boot-time.md).

**Measure with USB unplugged.** A cable attached at power-on makes U-Boot check
the charger first, and that lands in the arch counter. adb hot-plug works, so
attach afterwards.

## Tests

`tests/` is offline: none needs a device, and all run in a container.

```sh
for t in tests/test-*.sh; do "$t" || break; done
```

`test-update-roundtrip.sh` is the exception to "no inputs needed" — it runs the
real payload against the real image, and skips until `./build.sh` has run.

CI ([`.github/workflows/tests.yml`](.github/workflows/tests.yml)) runs the same
loop on every push and pull request, without a build.

## Releases

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs the full
build on GitHub's arm64 runner, then the tests including the round trip. Run
by hand from the Actions tab, it keeps the images as a workflow artifact. A
release is a tag matching `VERSION`:

```sh
git tag v1.4.0 && git push origin v1.4.0
```

The build then makes a **draft** release with the `.img.zip`, the `.bosupd` and
`SHA256SUMS`, marked pre-release if the version has a suffix (`1.4.0-beta.1`).
Write the notes and publish it from the releases page. A build from an empty
cache takes hours; ccache and the downloads are cached for the next.

## Conventions

- The vendor BL31, OP-TEE and SPL stay byte-for-byte. Replacing one is a design
  decision, not an implementation detail — write it into
  [docs/decisions.md](docs/decisions.md) first, as was done for U-Boot proper
  and the kernel.
- Stock-built software runs unmodified. What it needs from the kernel is
  provided by the kernel ([docs/mainline-compat.md](docs/mainline-compat.md)),
  with mainline's interface as the base and stock's as a thin layer over it;
  in `board/my355/linux`, `hardware/` is the board and `stock/` that layer.
- Claims in `docs/` are *verified* (observed on hardware) or *inferred* (from
  binaries). Retracted ones are kept, not deleted, in
  [docs/history.md](docs/history.md).
- No vendor binaries in git. The bundle is a release artifact, pinned by hash in
  `package/stock-firmware/`.
