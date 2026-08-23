# my355 · Boot budget

Where the ~18 s from power-on to frontend actually goes, and what a BaseOS port can
realistically reclaim.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

Rockchip's arch counter runs from SoC reset and U-Boot does not reset it, so kernel
timestamps are **power-on-relative**. This is confirmed by the reference serial log,
where U-Boot prints `Total: 3295.512/3340.136 ms` immediately before
`Starting kernel ...` and the first kernel line reads `[ 3.344904]`.

| phase | boundary | duration |
|---|---|---|
| bootrom + DDR training + SPL + BL31 + OP-TEE | → 0.39 s | **~0.39 s** |
| U-Boot | → 3.34 s (no card) / 4.29 s (card present) | **~2.9–3.9 s** |
| kernel → `/sbin/init` | 4.29 → 5.90 s | **1.61 s** |
| stock userland → frontend hand-off | 5.90 → 15.80 s | **9.90 s** |
| NextUI's own init | → ~18–20 s | ~2–4 s |

`launch.sh` (NextUI's entry point) starts at uptime 11.51 s = **15.80 s from power-on**.
That is the direct analogue of BaseOS's `boot-frontend-exec`, which is **2.96 s** on
RG40XXV ([05](../upstream-h700/docs/05-runtime-power-network.md)).

## BaseOS, measured end to end (2026-08-21)

Read over adb from a **cold** boot with USB unplugged (see the caveat below),
kernel stored gzipped. `/proc/uptime` is offset from the power-on-relative kernel
clock by a fixed amount — **uptime + 3.31 s = seconds from power-on** — pinned by
two events visible in both clocks: `jbd2/mmcblk1p3` starts at uptime 1.38 against
`EXT4-fs (mmcblk1p3): mounted` at 4.690, and `/data` at 1.52 against 4.825.

| phase | duration | at power-on | source |
|---|---|---|---|
| bootrom + DDR + SPL + BL31 | 0.39 s | 0.39 | [SD boot](02-sd-boot.md) |
| **vendor U-Boot 2017.09, from the card** | **2.75 s** | 3.14 | first printk |
| kernel → `Run /init` | 1.57 s | 4.71 | dmesg |
| busybox init → first `rcS` breadcrumb | 0.08 s | 4.79 | `/run/boot-rcS-start` |
| **`rcS`** | **0.07 s** | 4.86 | `/run/boot-rcS-done` |
| `rcS` → frontend exec | 0.05 s | 4.91 | `/run/boot-frontend-exec` |
| updater → `my355.sh` → `launch.sh` | 0.05 s | 4.96 | `/proc/<pid>/stat` field 22 |
| NextUI `launch.sh` prologue | 0.89 s | 5.85 | `nextui.elf` starttime |
| `nextui.elf` init → first frame | 1.77 s | **7.62** | `Freeing drm_logo memory` |

**Power-on to a usable frontend: ≈7.6 s, against ≈18.5 s on stock.**

"First frame" is the kernel releasing the bootloader framebuffer when userspace
takes the display over. Corroborated two ways: `nextui.txt` mtime lands in
21:25:04–06 (FAT's 2 s granularity → 6.8–8.8 s), and a stopwatch says 7–8 s.

| phase | stock | BaseOS | |
|---|---|---|---|
| pre-kernel | 4.26 s from NAND | **3.14 s** from SD | −1.1 s |
| kernel → `/init` | 1.61 s | 1.57 s | |
| userland → frontend hand-off | **9.90 s** | **0.20 s** | |
| **total to hand-off** | **15.8 s** | **4.91 s** | **−10.9 s** |

Essentially the entire vendor userland — `mount -a` over SPI NAND,
`udevadm settle --timeout=30`, then eight serialised `S*` scripts — is gone, and
BaseOS now boots from SD *faster than stock does from internal NAND*.

Nothing of ours is left on the critical path: `adbd` starts at 4.90 and `ntpd` at
4.87, both after the hand-off, and WiFi does not associate until 18.5 s.
The 0.89 s `launch.sh` prologue is NextUI's own script — FAT32 `mkdir`s,
`rm -rf .shadercache`, two synchronous `nextval.elf` calls, `touch && sync`,
`tinymix` — and is identical on stock, so it is not a BaseOS cost. It is,
however, now the second-largest single block in the boot.

> **Measuring caveat.** With a USB cable attached at power-on, U-Boot runs its
> charge animation (`/charge-animation`, `rockchip,uboot-charge`) before booting,
> and that time lands in the arch counter. It inflated readings to 7.18 s and
> 8.61 s. Measure with USB unplugged and attach it afterwards — adb hot-plug
> works on this device.

## Kernel compression: the big lever, measured

The vendor ships the kernel as a **raw 34.9 MiB arm64 `Image`** inside the boot
image, and U-Boot reads every byte off the card on each boot.

| stored as | size | share | pre-kernel |
|---|---|---|---|
| raw `Image` | 36 647 424 | 100% | 4.96 s |
| **gzip -9** | **12 991 358** | **35%** | **3.14 s** |
| lz4 -12 frame | 15 519 501 | 42% | 3.31 s |
| lz4 -9 legacy | 15 568 013 | 42% | does not boot — wrong framing |

**gzip saves 1.82 s** — over a third of the pre-kernel budget. The build asserts
`decompress(stored) == vendor kernel`, so the kernel is still the vendor's
byte-for-byte; only its storage changes. Default (`MY355_COMPRESS_KERNEL=gzip`).

### LZ4 boots, and loses

The first LZ4 card did not boot, which was read as "this U-Boot does not sniff
for LZ4 on the Android path". Wrong, and so was the reasoning: the evidence was
a byte-grep for the magic as a literal, but arm64 splits a 32-bit constant
across `movz`/`movk` bitfields, so that grep could not have found the check
either way. Disassembling the vendor U-Boot shows it:

```
android_image_get_comp(hdr) -> sniff(hdr + hdr->page_size)      @0xa29628
sniff(p):  zimage_parse_header(p) == 0     -> IH_COMP_ZIMAGE (6)
           lz4_valid_frame(p)              -> IH_COMP_LZ4    (5)  @0xaa83bc
           gzip_parse_header(p, 0xffff) >0 -> IH_COMP_GZIP   (1)
           lzma_check(p)                   -> IH_COMP_LZMA   (3)
           otherwise                       -> IH_COMP_NONE   (0)
```

`lz4_valid_frame` and `ulz4fn` accept only **frame** framing (`04 22 4d 18`)
with **independent blocks** — legacy `02 21 4c 18` is never tested for, and
linked blocks (`-BD`) get `-EPROTONOSUPPORT`. The failing card was legacy-framed:
its 15 568 013 bytes match `lz4 -9 -l` exactly. So `sniff` returned
`IH_COMP_NONE` and U-Boot jumped into the LZ4 header as if it were an `Image`.

`lz4 -12 -BI --no-frame-crc` boots, confirmed on hardware. It is also **0.17 s
slower than gzip**: 2.53 MiB more to read off the card costs more than the
faster inflate saves. gzip stays. (One cold boot each; the gap is small, but it
agrees with the size difference, so there is nothing to chase.)

`tools/rkbootimg.py` encodes the accept predicate and refuses to write a frame
this U-Boot would reject — the failure mode is a silent hang, so it is worth
making unrepresentable.

**zstd is not available.** No zstd magic appears in the disassembly as a
`movz`/`movk` immediate in either byte order, and there are no zstd strings:
this 2017.09 U-Boot predates `lib/zstd`. The four formats above are the set.

## Where the pre-kernel 3.14 s goes — measured (2026-08-22)

The pre-kernel budget is `fixed overhead + payload/read-rate + inflate`, and for a
long time those three terms could not be separated. Three boots — raw 4.96 s, gzip
3.14 s, lz4 3.31 s — are not enough: the raw/gzip pair moves payload size and
inflate work *together*, and the gzip/lz4 pair has too short a lever arm to invert
(deriving from its 0.17 s difference amplifies measurement noise into nonsense).

What separates them is a one-off build that zero-pads the stored gzip payload to
**exactly the raw kernel's size** (a temporary `--pad-kernel-to` in `rkbootimg.py`,
removed after the measurement — it is ~40 lines and the method is here). U-Boot reads
`kernel_size` bytes off the card and the inflater stops at the end of the stream,
ignoring the tail — so the padded boot does *identical* inflate work while reading
*identical* bytes to the raw boot. Two subtractions then fall out with no
simultaneous equations:

```
t_padded − t_gzip = (36 647 424 − 12 991 358) / read_rate      -> the read rate
t_padded − t_raw  = inflate                                    -> the inflate cost
```

Measured: **`t_padded` = 5.3057 s** against a 3.1395 s baseline on the same card,
same resource image, same rootfs, same session.

| term | measured | share |
|---|---|---|
| bootrom + DDR + SPL + BL31 | 0.39 s | 12% |
| **U-Boot's own initialisation** | **1.21 s** | **39%** |
| reading 12.99 MB off the card | 1.19 s | 38% |
| gzip inflate | 0.35 s | 11% |

**Card read rate: 10.9 MB/s.** The kernel drives the same card at SDR25/50 MHz
(`mmc1: new ultra high speed SDR25 SDXC card`, bus speed 50 MHz), which is ~25 MB/s
of headroom — so U-Boot is leaving better than half the available bandwidth unused.

Two consequences, and they reorder the plan:

1. **U-Boot's own init is the single largest item — larger than the read.** 1.21 s
   before it fetches a byte, spent on AVB/trusty probing, GPT repair, the
   charge-animation path, a full DRM bring-up and a SHA1 over the whole boot image.
   None of that is ours to keep.
2. **Compression is the *smaller* half.** zstd-19 is 10.82 MB against gzip's 12.99,
   so it is worth ~0.2 s of read plus whatever the inflate is worth — see the error
   bar below, which argues that second part is small. Real, but a fraction of what
   a lean U-Boot is worth.

> **Error bar, and what the lz4 point says.** The read rate rests only on the two
> 2026-08-21/22 boots, same card and session, and is solid. Splitting the remainder
> into fixed-overhead and inflate leans on the historical 4.96 s raw figure, so
> carry **±0.15 s** there.
>
> Feeding the lz4 boot through the same split gives a 0.285 s lz4 inflate — where a
> desktop intuition says LZ4 should be ~10x faster than gzip, not 0.8x. The likely
> reading is not that a number is wrong but that **both inflaters are bounded by
> memory bandwidth, not by CPU**: 0.346 s and 0.285 s are 106 and 128 MB/s of
> *output*, and both are writing the same 36.6 MB into DRAM. If that is right, the
> algorithm barely matters on this path and only the output size does.
>
> That caps what zstd can return. Expect the read half (12.99 → 10.82 MB ≈ 0.2 s)
> to be reliable and the inflate half to be worth ~0.05–0.1 s rather than the ~0.3 s
> a CPU-bound model predicts. **This is testable the same way**: pad a zstd payload
> to the raw size and compare. Worth one boot before attributing any zstd win.

### The kernel phase is close to its floor

`initcall_debug` (added in the same boot: padding only changes what happens *before*
the first printk, `initcall_debug` only what happens *after*, so neither pollutes the
other) attributes the 1.57 s. 793 initcalls, 1.14 s of accounted time:

| initcall | cost | can we remove it? |
|---|---|---|
| `tracer_init_tracefs` | **0.383 s** | no — ftrace/tracefs, a kernel *config* choice |
| `rk3x_i2c_driver_init` | 0.146 s | no — only the PMIC and muic buses are enabled already |
| `ohci_platform_init` | 0.118 s | no — the USB host is how the RTL8733BU WiFi/BT chip attaches |
| `alpu_init` | 0.112 s | no DT node exists; it is a driver-side i2c scan |
| `deferred_probe_initcall` | 0.063 s | — |
| `ehci_platform_init` | 0.033 s | no — same USB path |

`tracer_init_tracefs` is the 0.40 s silent gap seen in every earlier trace, between
`clocksource: Switched to arch_sys_counter` and `NET: Registered protocol family 2`.
It is now identified and it is **not reachable from the device tree** — the DTB is
ours to edit but this is `CONFIG_TRACING` building the tracefs event tree, so
removing it means rebuilding the kernel and giving up "the kernel is the vendor's,
byte-for-byte". The rest of the list is either load-bearing or already minimal, so
there is no cheap win left in the kernel phase.

## Compared with H700

Use the [H700 project README](../upstream-h700/README.md) figures, not
[h700/05](../upstream-h700/docs/05-runtime-power-network.md)'s marker table: that file labels its
`boot-*` markers "seconds since kernel start", but they are power-on-relative there
for the same reason they are here — the arch counter is not reset by the bootloader.
Read as kernel-relative they contradict the README and flatter us by ~2 s.

| | H700 (RG40XXV) | my355 | |
|---|---|---|---|
| LED → frontend hand-off | **2.96 s** | 4.91 s | we are 1.95 s behind |
| ├ bootloader + kernel + init | 2.04 s | 4.79 s | −2.75 s |
| └ `rcS` + hand-off | 0.92 s | **0.12 s** | **+0.80 s** |
| frontend init → input | 4.18 s | **2.71 s** | **+1.47 s** |
| **LED → input** | **7.14 s** | **7.62 s** | −0.48 s |

The two ports land within half a second of each other by *trading opposite
strengths*. Our userland is ~7x leaner than theirs and our NextUI init is 1.5 s
faster (an RK3566 with four A55s and a 50 MHz card against their A53s) — and the
entire 2.75 s deficit is the bootloader-and-kernel phase, which is large enough to
swallow both advantages.

**H700 has no U-Boot strategy to copy.** Per
[h700/00](../upstream-h700/docs/00-boot-chain-and-partitions.md), boot0, the U-Boot blobs, the
`env` partition and the vendor Android boot image are all kept **verbatim**;
`bootdelay=0` was already set by the vendor. That port replaces the rootfs and
nothing else. It works there because the vendor put the whole chain on the SD card
*and* their inherited bootloader is already fast. Neither holds here — ours starts
in NAND and spends 1.21 s initialising before it fetches a byte. "Don't touch the
bootloader" is a conclusion from their numbers, not a principle we inherit.

Remaining levers, now that the pre-kernel budget is decomposed:

1. **Tune the vendor U-Boot from its device tree — tried, 22 ms, dropped.** It
   swaps its control tree for our `rk-kernel.dtb`, so its knobs are ours to set,
   but there is no time in them. Notably the 10.9 MB/s read is **not** a UHS
   fallback — see [U-Boot](09-uboot.md).
2. **Ship our own U-Boot — 1.2–1.7 s.** The largest single item in the whole boot
   is the vendor U-Boot's 1.21 s of initialisation, and the read it then performs
   runs at 10.9 MB/s against ~25 MB/s of available bandwidth. The card already
   carries the `uboot` partition, so this needs **no NAND write** and is fail-safe.
   **Evaluated and shelved** — the boot path needs no reverse engineering, but
   mainline U-Boot has no VOP2 driver, so a boot logo means writing one. See
   [U-Boot](09-uboot.md).
3. **zstd for the kernel — 0.2–0.3 s.** Unlocked by (2), not independent of it: the
   blocker is not only that the vendor U-Boot lacks zstd, it is that the Android
   boot image path *sniffs* the format. A FIT declares `compression = "zstd"`, so
   nothing is sniffed. Shelved with (2).
4. **The kernel phase — nothing cheap left.** See the initcall table above.
5. **Shrink what U-Boot reads further.** The resource image is already rebuilt at
   442 880 bytes rather than the stock 943 616. Dropping the charge artwork would
   save another 176 KB, worth ~16 ms.

Projected with (2) and (3): pre-kernel **1.3–1.8 s**, power-on to input **5.8–6.3 s**.
Lever (1) claims part of the same ground more cheaply, so they do not add.
Not currently being pursued.

## Where the 9.9 s of userland goes

Sequential, all blocking, all before `S60mainui`:

- inittab `sysinit` `mount -a` (ext4 on SPI NAND) + `swapon` — init at 1.61 s uptime,
  `S00mountall`'s `mount-helper` does not start until 5.21 s
- `S10udev`: `udevd -d` + `udevadm trigger` ×2 + **`udevadm settle --timeout=30`**
- `S30dbus`, `S36load_wifi_modules`, `S40bluetooth`, `S40network`, `S41dhcpcd`,
  `S49ntp`, `S50dropbear`, `S50usbdevice`

This is exactly the class of work BaseOS deletes. Replacing the userland alone —
keeping the stock bootloader and kernel byte-for-byte — should land hand-off near
**5.5–6.5 s**, i.e. ~10 s reclaimed. Reaching H700-class numbers additionally requires
owning U-Boot, which costs another ~2 s.

## NextUI's vendor surface is small

`MinUI.pak/launch.sh` on `my355` touches only:

- `/sys/class/miyooio_chr_dev/joy_type` (in-kernel driver)
- `/usr/miyoo/lib` — three libraries (`libgamename.so`, `libshmvar.so`, `libtmenu.so`)
- `/usr/miyoo/bin/miyoo_inputd`

No `systemctl`, no `dmenu.bin` model detection, no vendor Bluetooth scripts. The whole
shim layer of H700 [01](../upstream-h700/docs/01-rootfs-and-init.md) [backup & recovery](03-nand-backup-and-recovery.md) largely evaporates. The stock
`runmiyoo.sh` is already a NextUI shim baked into the squashfs, chaining to
`/mnt/SDCARD/.tmp_update/updater`.

---

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
