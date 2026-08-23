# Contributing

## Development environment

macOS with Docker or OrbStack. Everything that touches a filesystem image or executes
AArch64 code runs in an unprivileged Alpine container, so the host needs neither sudo
nor loop mounts. `tools/docker-platform.sh` picks the platform per step: `linux/arm64`
where device binaries must run, the host architecture everywhere else.

Take a NAND backup of your own unit even if you build from the published bundle.
Making one, and recovering from a bad preloader write, are both in
[docs/03-nand-backup-and-recovery.md](docs/03-nand-backup-and-recovery.md). Read it
before flashing anything to `mtd5` — that is the one region where a mistake costs a
MASKROM recovery.

## The build

```sh
./fetch-prepared.sh                           # → work/my355/prepared/
./build-rootfs.sh                             # → work/my355/rootfs.tar
./build-image.sh                              # → work/my355/baseos-my355.img
```

To derive the inputs yourself instead of fetching them — which is what moving onto
a new vendor release needs — replace the first line with `./prepare-stock.sh
[NAND_DIR] [--boot PATH]`. It verifies the harvest is a **closed set**: every
`DT_NEEDED` of every harvested ELF must resolve inside the harvest, or the build
fails. That is what makes `manifest/harvest.list` a proof rather than a guess. What
it cannot see is `dlopen` and `system()`; those are in
[docs/08-rootfs.md](docs/08-rootfs.md).

Both paths land in the same place and get the same check —
`tools/source_manifest.py verify` runs at the start of `build-rootfs.sh` and
`build-image.sh`.

### Publishing a new bundle

After a `prepare-stock.sh` run against new firmware, `./cache-pack.sh` verifies,
packs, writes `manifest/prepared/*` and prints the `gh release create` line.
Publish before committing the manifests — they name a URL that has to resolve.
This distributes vendor firmware; see [NOTICE](NOTICE).

Build knobs:

| | |
|---|---|
| `MY355_COMPRESS_KERNEL` | `gzip` (default), `lz4`, `none`. Worth 1.8 s — [docs/01](docs/01-boot-budget.md) |
| `MY355_DIAG=1` | kernel-side LED heartbeat and `panic=10` — [docs/07](docs/07-bringup-and-diagnostics.md) |
| `MY355_LOGO_SIZE`, `MY355_LOGO_ASSET` | boot logo, rebuilt into the resource image |

## Debugging a device that cannot talk

No UART is attached and the vendor kernel has no framebuffer console, so a dead boot
and a good one look identical. Do not iterate blind —
[docs/07-bringup-and-diagnostics.md](docs/07-bringup-and-diagnostics.md) lists the
signals that do work, the failure signatures, and the point at which the right move is
to open the case and put a wire on `ttyS2` at 1500000 baud.

The decisive trick: put the BaseOS card in the **left** slot. It is not in the SPL boot
order, so the device boots stock from NAND and stock mounts the card under `/media/`,
where everything the failed boot wrote is readable over adb.

## Measuring the boot

Kernel timestamps are power-on-relative (the arch counter is not reset by the
bootloader); `/proc/uptime` is not. Pin the offset from two events visible in both
clocks — a `jbd2/mmcblk1p*` thread's `starttime` against its `EXT4-fs … mounted`
printk — then read the `/run/boot-*` breadcrumbs and `/proc/<pid>/stat` field 22.
Worked examples are in [docs/01-boot-budget.md](docs/01-boot-budget.md).

**Measure with USB unplugged.** With a cable attached at power-on, U-Boot runs its
charge animation first and that time lands in the arch counter. adb hot-plug works on
this device, so attach afterwards.

## Conventions

- The vendor kernel, U-Boot and BL31 stay byte-for-byte. If a change requires
  rebuilding one of them, that is a design decision, not an implementation detail —
  write it down in [docs/04-port-plan.md](docs/04-port-plan.md) first.
- Claims in `docs/` are marked *verified* (observed on hardware) or *inferred* (from
  binaries). Retracted claims are kept, not deleted, in
  [docs/05-investigation-log.md](docs/05-investigation-log.md).
- Nothing vendor-derived is committed to git. The prepared bundle is published as
  a release artifact and pinned by hash from `manifest/prepared/`; the repository
  itself stays free of vendor binaries.
