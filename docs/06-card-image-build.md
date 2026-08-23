# my355 · Building a BaseOS card

How `build-image.sh` composes a bootable card, and why each piece is
shaped the way it is. **This chain is verified end to end on hardware** — the
device boots from the card to userspace.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Prerequisite

The device must be running a **preloader with a working `/pinctrl`** in `mtd5`
([SD boot](02-sd-boot.md)). Without it the stock SPL cannot read an SD card at
all, and no card layout changes that.

## What the card must contain

The NAND boot chain reaches for exactly two things by **name**, then the kernel
reaches for a third by **number**:

| | why it is load-bearing |
|---|---|
| GPT partition `uboot`, **starting at sector 16384** | The SPL calls `part_get_info_by_name(dev, "uboot")` and reads the U-Boot FIT from the partition's *first sector*. |
| GPT partition `boot` | Stock U-Boot runs `boot_android mmc 1`, which resolves the Android boot image by this name. |
| rootfs as GPT **entry 3** | `root=/dev/mmcblk1p3` is baked into the DTB at build time. The name does not matter; the entry number does. |

The right slot enumerates as `mmcblk1` (left is `mmcblk2`) — fixed by DT aliases
`mmc0=sdhci`, `mmc1=fe2b0000`, `mmc2=fe2c0000`, so it does not vary.

## Layout

`tools/mkgpt.py` is the single source of truth; the build script reads it
via `--shell` rather than duplicating constants.

```
entry 1  uboot     16384 ..   32767     8 MiB   stock U-Boot FIT, verbatim
entry 2  boot      32768 ..  114687    40 MiB   Android boot image
entry 3  rootfs   114688 .. 1163263   512 MiB   slot A   <- root=/dev/mmcblk1p3
  —      (gap)   1163264 .. 2211839   512 MiB   slot B — update target, unallocated
entry 4  data    2211840 .. 2473983   128 MiB   ext4, persistent state
entry 5  primary 2473984 .. 2605055    64 MiB   FAT32, the only visible volume
```

The FAT volume is made with `-s 1`. At 63 MiB dosfstools would otherwise choose 4 KiB
clusters and produce 16092 of them, under the **65525 minimum a FAT32 must have** —
Linux's vfat driver mounts that anyway, but macOS validates the count and refuses, so
the card reads as damaged on a desktop. If `primary` is ever grown to fill the card,
reformat it rather than extending: 512-byte clusters do not scale to 58 GiB.

All three filesystems carry `miyoo355_fw.img`, the preloader installer stock picks up
off the card. All three, because which one stock's automounter mounts where is a lock
race with no reliable winner ([SD boot](02-sd-boot.md)).

Slot B is unallocated on purpose, mirroring the H700 A/B scheme
([docs/07](../upstream-h700/docs/07-partition-layout-and-updates.md)): it costs no visible
partition and no desktop offers to format it. Every entry but `primary` carries
GPT attribute bits 62 and 63, so a desktop assigns one drive letter.

**Reserving slot B now is free; adding it later is not** — it must sit between
`rootfs` and `data`, so retrofitting shifts every later partition and destroys
whatever is on the card.

## Boot image surgery

`tools/rkbootimg.py` rewrites the vendor Android boot image *in place*. The
kernel stays byte-for-byte vendor (`sha256 113c2d26…`); only these change:

| what | why |
|---|---|
| `/chosen/bootargs` in `rk-kernel.dtb` | repoint `root=` at the card |
| `logo.bmp`, `logo_kernel.bmp` | tell, on a console-less device, whether U-Boot came from the card or NAND. Size is ours to choose — see below |
| `linux,default-trigger` on `/leds/work` | diagnostics only (`MY355_DIAG=1`) |
| the header's SHA1 `id` | **mandatory** — see below |

The kernel and every other resource entry are copied verbatim; the tool asserts
the kernel hash and the resource entry set after writing.

### The resource image is rebuilt, not patched

Early versions patched the vendor resource in place, which forced our logo to
match the vendor's exact byte count. That turned out to matter for a reason
nothing warned about:

**A 943 616-byte resource hangs this U-Boot before display init** — no backlight,
no logo, nothing. 465 408 bytes boots. The stock image's two 480x198 logos are
what push it over; the exact threshold is unmeasured, somewhere between the two.

Symptom to recognise: *the backlight never lights at all*. That is different from
a blank logo, and it means U-Boot never reached display init — it reads the
resource image, and uses `rk-kernel.dtb` from it as its own control device tree,
before it touches the display.

`ResourceImage.build()` therefore composes a fresh resource image, so the logo is
sized for looks and for headroom rather than to match the vendor. The default
`240x48` lands the resource at **442 880 bytes**, comfortably under the largest
size proven to boot. `rkbootimg.py` warns above `RESOURCE_SAFE_BYTES`.

### The boot image `id` is verified

The `ANDROID!` header carries a SHA1 over `kernel|size · ramdisk|size ·
second|size`. U-Boot checks it (`ANDROID: Hash OK`) and **refuses the image if
it is stale**. Any edit to the resource image must refresh it.

This produces a deeply misleading failure: U-Boot reads the resource image
*early and unverified* to fetch the DTB and draw the logo, so a replaced logo
appears normally — and then nothing boots. `rkbootimg.py` now recomputes the id
on every repack and asserts it before writing; `info` reports `valid`/`STALE`.

### The command line budget is exactly zero

The vendor line uses **100 of 100** available bytes, and in-place FDT patching
cannot grow it. Dropping `earlycon=` (dead weight with no UART attached) buys
the room for what is actually needed:

```
console=ttyFIQ0 root=/dev/mmcblk1p3 rootfstype=ext4 rootwait rw init=/init
```

**`init=/init` is required.** For a *disk* root the kernel only tries
`/sbin/init`, `/etc/init`, `/bin/init`, `/bin/sh` — `/init` is the initramfs
convention. Without it the kernel execs `/bin/sh`, which then waits forever on a
console that does not exist: LED alive, root mounted, nothing happening, no
panic. The H700 port sets `init=/init` too ([docs/01](../upstream-h700/docs/01-rootfs-and-init.md) §3).

`rkbootimg.py info` reports the budget, so this cannot be discovered the hard way.

The logo is the project wordmark, cropped from `assets/bootlogo.bmp` and scaled
to `--size` (default `240x48`). The artwork's near-black gradient backdrop is
subtracted so it composites to true black — otherwise it shows as a lighter
rectangle against the panel.

### Check the logo before spending a boot

`mkbootlogo.py` prints a percent-painted figure and `--preview` renders
ASCII, both run by the build. A logo that renders almost blank looks exactly like
a boot failure on this device, and did once: the vendor BMP is **top-down**
(`height = -198`), and using the raw negative height in the scale calculation
silently produced 5x7-pixel text.

### The kernel is stored compressed

The vendor kernel is a raw 34.9 MiB arm64 `Image`; U-Boot reads all of it off the
card each boot. Storing it gzipped (12.99 MiB, 35%) takes pre-kernel time from
**4.96 s to 3.14 s** — see [01](01-boot-budget.md).

`MY355_COMPRESS_KERNEL` selects `none | gzip | lz4`. Both compressed formats
boot; gzip is the default because it is smaller and measured faster (3.14 s vs
3.31 s). LZ4 must be frame-framed with independent blocks, which `rkbootimg.py`
enforces — the 2026-08-20 "LZ4 does not boot" card was legacy-framed.

The build asserts `decompress(stored) == vendor kernel` before writing, so the
"vendor kernel byte-for-byte" property is preserved — only its storage changes.

## ext4 features

`^orphan_file` only. This kernel is **5.10.160**: `orphan_file` needs 5.15+, but
`metadata_csum`, `metadata_csum_seed` and `64bit` are all fine — unlike the H700
port, which must disable them for its 4.9 kernel
([docs/00](../upstream-h700/docs/00-boot-chain-and-partitions.md) §3). Verified: the vendor kernel
mounts these filesystems.

## Build and flash

```sh
./build-rootfs.sh --smoke          # or the real rootfs, once it exists
./build-image.sh [NAND_BACKUP_DIR] # default: ~/Development/miyoo-flip-nand-backup
```

`MY355_DIAG=1` adds bring-up aids — see
[bring-up and diagnostics](07-bringup-and-diagnostics.md).

The build verifies as it goes: `sgdisk -v` clean, `e2fsck -fn` on both ext4
filesystems, the boot image id valid, and the kernel hash unchanged.

Flashing (macOS; **check the disk number every time**, it moves):

```sh
diskutil list external
diskutil unmountDisk /dev/diskN && sudo dd if=work/my355/baseos-my355.img of=/dev/rdiskN bs=4m
```

Then the card goes in the **right slot** — the only slot in the SPL's boot order.

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
