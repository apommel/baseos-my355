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
  —      (spare)   32768 ..   49151     8 MiB
entry 2  boot      49152 ..  131071    40 MiB   Android boot image
  —      (spare)  131072 ..  212991    40 MiB
entry 3  rootfs   212992 .. 1261567   512 MiB            <- root=/dev/mmcblk1p3
  —      (spare) 1261568 .. 2310143   512 MiB
entry 4  data    2310144 .. 2572287   128 MiB   ext4, persistent state
entry 5  primary 2572288 .. 2703359    64 MiB   FAT32, the only visible volume
```

`primary` ships at 64 MiB and is grown to fill the card on the first boot (below).
Until then it is made with `-s 1`: at 63 MiB dosfstools would otherwise choose 4 KiB
clusters and produce 16092 of them, under the **65525 minimum a FAT32 must have** —
Linux's vfat driver mounts that anyway, but macOS validates the count and refuses, so
a freshly flashed card would read as damaged on a desktop.

All three filesystems carry `miyoo355_fw.img`, the preloader installer stock picks up
off the card. All three, because which one stock's automounter mounts where is a lock
race with no reliable winner ([SD boot](02-sd-boot.md)).

Each of the three updatable regions reserves twice what it needs, and only one
half is ever a partition; the spare is where an update writes (below). Leaving it
unallocated is what makes A/B free: it costs no visible partition and no desktop
offers to format it. Every entry but `primary` carries GPT attribute bits 62 and
63, so a desktop assigns one drive letter.

**Reserving the spare halves now is free; adding them later is not** — each must
sit immediately behind its partition, so retrofitting shifts everything after it
and destroys whatever is on the card. 0.2.x cards, which reserved only the rootfs
half, need one last reflash for that reason.

**Nothing may regenerate the GPT after the first boot.** `mkgpt.py` writes the
64 MiB `primary` of the shipped image; running it against a card that has already
been expanded would shrink the partition back and orphan everything on it. An
update rewrites three entries of the existing table; it never rebuilds it.

## First boot: expand to fill

`rcS` runs `usr/sbin/expand-storage` once — after `/data` is mounted, before the
card is. It grows `primary` to the end of the card, reformats it, and puts back
what was on it.

`usr/sbin/gptgrow` (from `src/gptgrow.c`, static, zero dependencies) does the table
work: move the entry's ending LBA to the last usable sector of the real device,
rewrite both GPT copies and the protective MBR with recomputed CRCs, then
`BLKPG_RESIZE_PARTITION`. That ioctl is the point — a full partition-table reread
is refused with `EBUSY` while the rootfs on the same disk is mounted. It takes the
partition by **name** and refuses anything that is not MS basic data, so a wrong
argument cannot land a `mkfs` on `rootfs`. Exit codes: 0 grew, 1 already full,
2 error.

Growing FAT32 in place would need `fatresize`; reformatting is what BusyBox can do,
and it fixes the cluster size on the way. BusyBox's `mkfs.vfat` is FAT32-only and
picks the cluster size itself — `-F`, `-s` and `-S` are accepted and ignored —
landing on 4 KiB up to a few GiB and 16 KiB from 16 GiB up.

Unlike the H700 port this partition is **not empty**: the preloader installer
leaves `mtd5-original-<hash>.img`, the user's only copy of their original
preloader, on it. So its contents are staged on `/data` first (95 MiB free against
a 62 MiB volume) and restored after the `mkfs`. Staging counts as complete only
once the directory is renamed into place, and `/data/expanded` is written last, so
a power cut leaves work the next boot redoes rather than files it has lost. A card
that already fills the disk with nothing staged is marked done and left alone — it
is not a card we grew.

Verified on hardware (64 GB card, 2026-08-25): 64 MiB → 57.0 GiB with **16 KiB
clusters** (3 737 821 of them) in **1.1 s**, card files intact, nothing done on
later boots. macOS mounts the result.

## Updates

`./build-update.sh` turns a composed image into `baseos-my355-<version>.bosupd`:
an uncompressed tar of a manifest and one gzipped slot image per region, ~34 MB.
Users copy it to the root of either card and power on.

`usr/sbin/baseos-update apply` runs from `rcS` just after the card mount:

```
1  read every *.bosupd's manifest — on the frontend card, then on this card's own
   `primary` if that is not already it (a read-only mount, on every boot)
2  it must be built for my355, fit these slots, be newer than the running version
   (or a rebuild of it), and not already be in /data/update/history
3  write all three slot images into the spare halves, 32 MiB at a time
4  read each half back and hash it                        -> mismatch: stop here
5  gptslot flip uboot boot rootfs                             <- the commit point
6  record the commit, then reboot
```

Step 5 is the only irreversible action and every check precedes it, so power loss
at any earlier moment leaves the card byte-identical to before. `data` and
`primary` are never written, which is the whole point: an update keeps ROMs,
saves and settings that a reflash would destroy.

All three regions are written every time, even when only the rootfs changed.
Comparing first would save 48 MiB of writes and cost a special case, because the
running rootfs is mounted `rw` and so never matches its own image.

`usr/sbin/gptslot` (from `src/gptslot.c`) does the arithmetic and derives the
geometry from the table alone: the regions tile forward from LBA 16384 — the one
address the SPL fixes — each twice its entry's size, and `data` must start exactly
where the last one ends. A card without the spare halves fails that check and
cannot be flipped, which is what stops this touching a 0.2.x card.

Nothing in the boot chain references an address, which is what makes a GPT write
enough to select all three: the SPL finds `uboot` by name, `boot_android` finds
`boot` by name, and `root=/dev/mmcblk1p3` names an entry number.

**Rollback.** `rcS` runs `baseos-update boot-check`, which counts boots while a
trial is open and restores the previous halves on the third; `nextui-session` runs
`baseos-update confirm` as it starts, which ends the trial. Confirming on session
start rather than on frontend hand-off is deliberate — a card with no frontend is
a healthy OS, and keying the trial later would make that look like a failed update
and roll back forever. This cannot cover a rootfs so broken that `/init` never
runs; that stays a reflash.

There is deliberately no signing key: it would be a single point of failure for
every update, and these images carry no secrets. Integrity is the SHA-256 per
region, verified by reading back what was written.

`baseos-update status` prints what is installed and the verdict for every payload
it can see — the apply path is silent about the ones it skips, since it runs on
every boot.

The preloader in NAND and the layout itself stay out of reach; changing either
still means reflashing.

Verified on hardware (2026-08-27, 0.3.0): a 34 MB payload wrote and verified all
three regions — 560 MiB — in **49.6 s**, flipped, and rebooted running `uboot`,
`boot` and `rootfs` from their second halves, with `data` and the card's files
untouched; the trial closed on the next session start. That run settled the
design's last assumption: the SPL really does find `uboot` by name at LBA 32768
and `boot_android` finds `boot` at 131072, so neither is pinned to the address it
shipped at. An ordinary boot costs ~15 ms for the check, ~85 ms when a payload is
left on the card and has to be weighed up again.

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

`MY355_SD_UHS` raises the boot slot's UHS ceiling: `sdr104` (default), `sdr50`,
or `off` for the vendor's SDR25. `tools/rkbootimg.py` inserts the missing
`sd-uhs-*` flags into `dwmmc@fe2b0000` in every `rk-kernel.dtb*` — the only patch
here that *grows* the FDT rather than rewriting a value in place, so it relays
out the struct and strings blocks and reads the result back before returning.
Slot 1 is left alone: it shares `vccio_sd`. See
[docs/01](01-boot-budget.md#the-sd-bus-was-capped-in-the-device-tree-2026-08-24).

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
