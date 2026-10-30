# The card

How `build-image.sh` composes a bootable card, what is on it, and what first
boot and updates do to it. The rootfs that goes inside is [rootfs](rootfs.md);
the boot chain that reaches it is [boot chain](boot-chain.md).

## Prerequisite

The device must be running a **preloader with a working `/pinctrl`** in `mtd5`
([SD boot](boot-chain.md)). Without it the stock SPL cannot read an SD card at
all, and no card layout changes that.

## What the card must contain

The NAND boot chain reaches for exactly two things by **name**, then the kernel
reaches for a third by **number**:

| | why it is load-bearing |
|---|---|
| GPT partition `uboot`, **starting at sector 16384** | The SPL calls `part_get_info_by_name(dev, "uboot")` and reads the U-Boot FIT from the partition's *first sector*. |
| GPT partition `boot` | Our U-Boot's boot script finds it by name with `part start`/`part size` and reads the FIT behind its header ([U-Boot](uboot.md)); the vendor U-Boot's `boot_android mmc 1` does the same for its Android boot image. |
| rootfs as GPT **entry 3** | `root=/dev/mmcblk1p3` is baked into the DTB at build time. The name does not matter; the entry number does. |

The right slot enumerates as `mmcblk1` (left is `mmcblk2`) — fixed by DT aliases
`mmc0=sdhci`, `mmc1=fe2b0000`, `mmc2=fe2c0000`, so it does not vary.

## Layout

`tools/mkgpt.py` is the single source of truth; the build script reads it
via `--shell` rather than duplicating constants.

```
entry 1  uboot     16384 ..   32767     8 MiB   U-Boot FIT: ours + vendor BL31/OP-TEE
  —      (spare)   32768 ..   49151     8 MiB
entry 2  boot      49152 ..  131071    40 MiB   kernel + DTB: a FIT
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
off the card. Stock mounts `/data` and the FAT volume, which race for the one
mountpoint it reads, with no reliable winner ([SD boot](boot-chain.md)); the root,
EROFS, it skips, and `expand-storage` copies the root's onto the FAT volume it
formats.

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

`rcS` runs `expand-storage` once — after `/data` is mounted, before the
card is. It grows `primary` to the end of the card, reformats it, and puts back
what was on it.

`gptgrow` (from `src/gptgrow.c`, static, zero dependencies) does the table
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

This partition is **not empty**: the preloader installer
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

`baseos-update apply` runs from `rcS` just after the card mount:

```
1  read every *.bosupd's manifest — on the frontend card, then on this card's own
   `primary` if that is not already it (a read-only mount, on every boot)
2  it must be built for my355, fit these slots, be newer than the running version
   (or a rebuild of it), and not already be in /data/update/history
3  write each changed slot image into its spare half, 32 MiB at a time
4  read each written half back and hash it                -> mismatch: stop here
5  gptslot flip <the written regions>                         <- the commit point
6  record the commit, then reboot
```

Step 5 is the only irreversible action and every check precedes it, so power loss
at any earlier moment leaves the card byte-identical to before. `data` and
`primary` are never written, which is the whole point: an update keeps ROMs,
saves and settings that a reflash would destroy.

Only regions that change are written. Nothing writes to a running slot — the
rootfs is mounted read-only — so hashing the active half of `uboot` and `boot`
says whether the payload would change them, and both builds reproduce
(`SOURCE_DATE_EPOCH=0`, FIT timestamp 0), so most releases leave them alone and
skip 48 MiB of writes plus their read-back. A region left alone is not flipped,
and a rollback flips back only what the update flipped (`regions=` in
`/data/update/state`). The rootfs is never compared: it carries the build stamp,
so every applicable payload changes it, and hashing 512 MiB to learn that would
cost seconds. The payload still carries all three images, so it applies to a card
on any earlier release.

`gptslot` (from `src/gptslot.c`) does the arithmetic and derives the
geometry from the table alone: the regions tile forward from LBA 16384 — the one
address the SPL fixes — each twice its entry's size, and `data` must start exactly
where the last one ends. A card without the spare halves fails that check and
cannot be flipped, which is what stops this touching a 0.2.x card.

Nothing in the boot chain references an address, which is what makes a GPT write
enough to select all three: the SPL finds `uboot` by name, U-Boot finds
`boot` by name, and `root=/dev/mmcblk1p3` names an entry number.

**Rollback.** `rcS` runs `baseos-update boot-check`, which counts boots while a
trial is open and restores the previous halves on the third; `frontend-session` runs
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

## The boot FIT

`tools/mkfit.py boot` packs the kernel (zstd, tuned for U-Boot's decoder) and
`rk3566-miyoo-flip.dtb` into a FIT, behind a 512-byte header that carries its
length ([U-Boot](uboot.md), *How this build works*). Nothing is edited on the
way: the command line is the device tree's own `/chosen/bootargs`, and the
tool only checks that it names the `root=` `mkgpt.py` derives and that the tree
reserves OP-TEE, then reads the kernel and the tree back out of what it wrote.

**`init=/init` is required.** For a *disk* root the kernel only tries
`/sbin/init`, `/etc/init`, `/bin/init`, `/bin/sh` — `/init` is the initramfs
convention. Without it the kernel execs `/bin/sh`, which then waits forever on a
console that does not exist: root mounted, nothing happening, no panic.

The vendor Android boot image this replaced, and what it took to edit it, is in
[history](history.md).

## Filesystems

The root is EROFS (lz4hc, 16 KiB clusters; [rootfs](rootfs.md)), which stock
does not mount. `/data` is ext4 with `^orphan_file` only: the stock 5.10.160 kernel has no `orphan_file` (5.15+), and
reading a BaseOS card from stock, in the left slot, is how a failed boot is
debugged ([diagnostics](diagnostics.md)). `metadata_csum`, `metadata_csum_seed`
and `64bit` are all fine there.

## Build and flash

```sh
./fetch-prepared.sh                # or ./prepare-stock.sh NAND_DIR
./build-all.sh                     # U-Boot, kernel, GPU, rootfs, image, .bosupd
```

`build-all.sh` runs the steps below, each of which also stands alone:
`build-uboot.sh`, `build-kernel.sh` and `build-gpu.sh` (cached trees, so a
rerun is incremental), `build-rootfs.sh` (harvest + overlay + BusyBox),
`build-image.sh` (this page) and `build-update.sh` (the `.bosupd` payload).

The build verifies as it goes: `sgdisk -v` clean, `fsck.erofs` on the root,
`e2fsck -fn` on `/data`, and the kernel and device tree read back out of the boot FIT.

Flashing, on macOS:

```sh
./flash-card.sh          # lists the candidates — the disk number moves between runs
./flash-card.sh diskN
```

It writes `work/my355/baseos-my355.img` to the raw node, and refuses before
writing anything unless the disk is physical **removable** media at least the
size of the image: every SSD, internal or external, reports itself `Fixed`, and
a mounted disk image reports `Virtual`. It then asks for the disk name typed
back. Anywhere else, any image writer does ([INSTALL](../INSTALL.md)).

Then the card goes in the **right slot** — the only slot in the SPL's boot order.
