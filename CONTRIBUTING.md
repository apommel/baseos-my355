# Contributing

## Development environment

macOS with Docker or OrbStack. Anything touching a filesystem image or running
AArch64 code goes in an unprivileged Alpine container, so the host needs no sudo and
no loop mounts. `tools/docker-platform.sh` picks the platform per step: `linux/arm64`
for device binaries, host arch otherwise.

Take a NAND backup even if you build from the bundle. Making one, and recovering from
a bad preloader write, are in
[docs/03-nand-backup-and-recovery.md](docs/03-nand-backup-and-recovery.md) — read it
before writing anything to `mtd5`, the one region where a mistake costs a MASKROM
recovery.

## The build

```sh
./fetch-prepared.sh                           # → work/my355/prepared/
./build-rootfs.sh                             # → work/my355/rootfs.tar
./build-image.sh                              # → work/my355/baseos-my355.img
```

To derive the inputs instead — needed to move onto a new vendor release — replace
the first line with `./prepare-stock.sh [NAND_DIR] [--boot PATH]`. It verifies the
harvest is a **closed set**: every `DT_NEEDED` of every harvested ELF must resolve
inside it, or the build fails. That is what makes `manifest/harvest.list` a proof
rather than a guess. It cannot see `dlopen` or `system()`; those are in
[docs/08-rootfs.md](docs/08-rootfs.md).

Both paths get the same check — `tools/source_manifest.py verify` runs at the start
of `build-rootfs.sh` and `build-image.sh`.

### Publishing a new bundle

After a `prepare-stock.sh` run against new firmware, `./cache-pack.sh` verifies,
packs, writes `manifest/prepared/*` and prints the `gh release create` line.
Publish before committing the manifests — they name a URL that has to resolve.
This distributes vendor firmware; see [NOTICE](NOTICE).

Build knobs:

| | |
|---|---|
| `MY355_COMPRESS_KERNEL` | `gzip` (default), `lz4`, `none`. Worth 1.8 s — [docs/01](docs/01-boot-budget.md) |
| `MY355_SD_UHS` | boot-slot UHS ceiling: `sdr104` (default), `sdr50`, `off`. The vendor DTB caps at SDR25; measured 22.3 → 63.0 MB/s and 1.06 s off the boot — [docs/01](docs/01-boot-budget.md) |
| `MY355_DIAG=1` | kernel-side LED heartbeat and `panic=10` — [docs/07](docs/07-bringup-and-diagnostics.md) |
| `MY355_LOGO_SIZE`, `MY355_LOGO_ASSET` | boot logo, rebuilt into the resource image |

## Debugging a device that cannot talk

No UART is attached and the vendor kernel has no framebuffer console, so a dead boot
looks like a good one. Do not iterate blind —
[docs/07-bringup-and-diagnostics.md](docs/07-bringup-and-diagnostics.md) lists the
signals that work, the failure signatures, and when to open the case and put a wire
on `ttyS2` at 1500000 baud.

The decisive trick: put the BaseOS card in the **left** slot. It is not in the SPL
boot order, so the device boots stock from NAND and mounts the card under `/media/`,
where everything the failed boot wrote is readable over adb.

## Measuring the boot

Kernel timestamps are power-on-relative (the bootloader does not reset the arch
counter); `/proc/uptime` is not. Pin the offset — a `jbd2/mmcblk1p*` `starttime`
against its `EXT4-fs … mounted` printk, or an uptime reading echoed into `/dev/kmsg`
— then read the `/run/boot-*` breadcrumbs and `/proc/<pid>/stat` field 22. Worked
examples in [docs/01-boot-budget.md](docs/01-boot-budget.md).

**Measure with USB unplugged.** A cable attached at power-on makes U-Boot run its
charge animation first, and that lands in the arch counter. adb hot-plug works, so
attach afterwards.

## Conventions

- The vendor kernel, U-Boot and BL31 stay byte-for-byte. Rebuilding one is a design
  decision, not an implementation detail — write it into
  [docs/04-port-plan.md](docs/04-port-plan.md) first.
- Claims in `docs/` are *verified* (observed on hardware) or *inferred* (from
  binaries). Retracted ones are kept, not deleted, in
  [docs/05-investigation-log.md](docs/05-investigation-log.md).
- No vendor binaries in git. The bundle is a release artifact, pinned by hash from
  `manifest/prepared/`.
