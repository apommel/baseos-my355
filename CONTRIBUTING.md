# Contributing

## Development environment

macOS or Linux, x86_64 or ARM, with Docker or OrbStack. Anything touching a
filesystem image or running AArch64 code goes in an unprivileged Alpine container, so
the host needs no sudo and no loop mounts. `tools/common.sh` picks the platform per
step: `linux/arm64` for device binaries, host arch otherwise. Set
`BASEOS_DOCKER_PLATFORM_HOST` to override the latter.

On an x86_64 host the `linux/arm64` steps (`build-rootfs.sh`) run under QEMU, which
needs binfmt handlers registered. Docker Desktop and OrbStack ship them; a plain
Docker Engine does not, and `build-rootfs.sh` says so rather than letting the
container die with `exec format error`:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

Take a NAND backup even if you build from the bundle. Making one, and recovering from
a bad preloader write, are in
[docs/recovery.md](docs/recovery.md) — read it
before writing anything to `mtd5`, the one region where a mistake costs a MASKROM
recovery.

## The build

```sh
./fetch-prepared.sh                           # → work/my355/prepared/
./build-rootfs.sh                             # → work/my355/rootfs.tar
./build-image.sh                              # → work/my355/baseos-my355.img
./build-update.sh                             # → the .bosupd payload
./flash-card.sh diskN                         # macOS: the image → an SD card
```

`./build-all.sh` runs all four and packages the release. To derive the inputs
instead — needed to move onto a new vendor release — replace the first line with
`./prepare-stock.sh NAND_DIR`, whose three `mtd*.img` files are described in
[docs/recovery.md](docs/recovery.md). It verifies the harvest is a
**closed set**: every `DT_NEEDED` of every harvested ELF must resolve inside it, or
the build fails. That is what makes `manifest/harvest.list` a proof rather than a
guess. It cannot see `dlopen` or `system()`; those are in
[docs/rootfs.md](docs/rootfs.md).

Both paths get the same check — `tools/source_manifest.py verify` runs before
every build step, and in `fetch-prepared.sh` and `cache-pack.sh`. Besides the
hashes in `source.json`, it checks the harvest's paths against
`manifest/harvest.list`, because those hashes still match an old tar after the
list changes. So **editing the list means re-running `prepare-stock.sh`**, and
`cache-pack.sh` after it so the published bundle follows.

### Publishing a new bundle

After a `prepare-stock.sh` run against new firmware, `./cache-pack.sh` verifies,
packs, writes `manifest/prepared/*` and prints the `gh release create` line.
Publish before committing the manifests — they name a URL that has to resolve.
This distributes vendor firmware; see [NOTICE](NOTICE).

Build knobs:

| | |
|---|---|
| `MY355_COMPRESS_KERNEL` | `gzip` (default) or `none`. Worth 1.8 s — [boot time](docs/boot-time.md) |
| `MY355_SD_UHS` | boot-slot UHS ceiling: `sdr104` (default), `sdr50`, `off`. The vendor DTB caps at SDR25; measured 22.3 → 63.0 MB/s and 1.06 s off the boot — [boot time](docs/boot-time.md) |
| `MY355_INITCALL_BLACKLIST` | built-in initcalls skipped by name; empty restores the vendor set. Worth 0.71 s — [boot time](docs/boot-time.md) |
| `MY355_LOGO_SIZE`, `MY355_LOGO_ASSET` | boot logo, rebuilt into the resource image |

## Debugging a device that cannot talk

No UART is attached and the vendor kernel has no framebuffer console, so a dead boot
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

**Measure with USB unplugged.** A cable attached at power-on makes U-Boot run its
charge animation first, and that lands in the arch counter. adb hot-plug works, so
attach afterwards.

## Tests

`tests/` is offline: none needs a device, and all but `test-harvest-drift.sh`,
which is plain host Python, run in a container.

```sh
for t in tests/test-*.sh; do "$t" || break; done
```

`test-update-roundtrip.sh` is the exception to "no inputs needed" — it runs the
real payload against the real image, so `./build-all.sh` has to have run first.

## Conventions

- The vendor kernel, U-Boot and BL31 stay byte-for-byte. Rebuilding one is a design
  decision, not an implementation detail — write it into
  [docs/decisions.md](docs/decisions.md) first.
- Claims in `docs/` are *verified* (observed on hardware) or *inferred* (from
  binaries). Retracted ones are kept, not deleted, in
  [docs/history.md](docs/history.md).
- No vendor binaries in git. The bundle is a release artifact, pinned by hash from
  `manifest/prepared/`.
