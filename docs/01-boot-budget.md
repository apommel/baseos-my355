# my355 · Boot budget

Where the 31.5 s from power-on to a NextUI frame on stock actually goes, what BaseOS
reclaims, and what is left.

> **Provenance.** Measured on hardware over adb. The end-to-end stock and BaseOS
> figures below are from **2026-08-23**, one cold boot each, USB unplugged at
> power-on. Earlier structural findings are from 2026-08-19/22 and are dated where
> they matter. Claims are *verified* (observed on hardware) or *inferred* (from
> binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Reading the two clocks

Rockchip's arch counter runs from SoC reset and U-Boot does not reset it, so kernel
timestamps are **power-on-relative**. This is confirmed by the reference serial log,
where U-Boot prints `Total: 3295.512/3340.136 ms` immediately before
`Starting kernel ...` and the first kernel line reads `[ 3.344904]`.

`/proc/uptime` is not: it starts at timekeeping init, 0.16–0.19 s after the first
printk. Process `starttime` (`/proc/<pid>/stat` field 22, USER\_HZ = 100) is on that
clock, so pin the per-boot offset before reading the two together.

* **Direct.** `u=$(cut -d" " -f1 /proc/uptime); echo "probe $u" > /dev/kmsg`, then
  read the printk timestamp back; the difference is the offset. Three probes on the
  stock boot: 4.495 / 4.491 / 4.498 → **4.49 s**.
* **By anchor.** A `jbd2/mmcblk1p*` thread's `starttime` against its
  `EXT4-fs … mounted` printk — 1.39/4.686 and 1.53/4.823 → **3.295 s**, agreeing to
  2 ms.

Stock's root is squashfs, so it has no ext4 anchor; use the probe there.

## Stock, measured end to end (2026-08-23)

`uptime + 4.49 = seconds from power-on`. The USB cable was attached at 37 s, well
after the frame, so no charge animation is in these numbers.

| phase | duration | at power-on | source |
|---|---|---|---|
| bootrom + DDR + SPL + BL31 + **U-Boot, from NAND** | 4.30 s | 4.30 | first printk `4.295967` |
| kernel → `/sbin/init` | 1.61 s | 5.91 | `Freeing unused kernel memory` |
| init → `S01syslogd` | 4.27 s | 10.18 | `/proc/<pid>/stat` |
| `S10udev` … `S50usbdevice` | 5.23 s | 15.41 | dbus 12.85, ntp 14.38, dropbear 14.85 |
| `S60mainui` → `runmiyoo.sh` → `updater` → `my355.sh` | 0.24 s | 15.79 | |
| **frontend hand-off — `launch.sh` starts** | | **15.79** | |
| `launch.sh` starts `miyoo_inputd`, `keymon`, `batmon`, `audiomon` | 0.15 s | 15.94 | |
| **NextUI `launch.sh` prologue** | **12.45 s** | 28.39 | `nextui.elf` starttime 2390 |
| `nextui.elf` init → first frame | 3.11 s | **31.50** | `Freeing drm_logo memory` |

**Power-on to a NextUI frame on stock: 31.50 s** — matching the 28–32 s a stopwatch
gives, which the older ~18 s estimate never did.

The 15.79 s hand-off reproduces the 15.80 s measured 2026-08-19. The line after it
was the error: NextUI's own init, guessed at 2–4 s, is **15.7 s**.

## BaseOS, measured end to end (2026-08-23)

`uptime + 3.295 = seconds from power-on`, kernel stored gzipped, cold boot with USB
unplugged.

| phase | duration | at power-on | source |
|---|---|---|---|
| bootrom + DDR + SPL + BL31 | 0.39 s | 0.39 | [SD boot](02-sd-boot.md) |
| **vendor U-Boot 2017.09, from the card** | **2.74 s** | 3.13 | first printk `3.134233` |
| kernel → `Run /init` | 1.51 s | 4.64 | dmesg `4.644068` |
| busybox init → first `rcS` breadcrumb | 0.08 s | 4.73 | `/run/boot-rcS-start` |
| ├ tmpfs skeleton, `lo`, `/data` mount | 0.04 s | 4.77 | `/run/boot-data-mounted` |
| ├ machine-id + BlueZ links | 0.01 s | 4.78 | `/run/boot-dbus-start` |
| ├ **`dbus-daemon --system`** | **0.14 s** | 4.92 | `dbus-daemon` starttime |
| └ frontend card mount, background tasks | 0.01 s | 4.93 | `/run/boot-rcS-done` |
| **`rcS`** | **0.20 s** | 4.93 | |
| init spawns `nextui-session` | 0.02 s | 4.95 | `/proc/<pid>/stat` |
| **frontend hand-off — `exec updater`** | 0.03 s | **4.98** | `/run/boot-frontend-exec` |
| `updater` → `my355.sh` → `launch.sh` | 0.08 s | 5.06 | |
| NextUI `launch.sh` prologue | 0.89 s | 5.95 | `nextui.elf` starttime |
| `nextui.elf` init → first frame | 1.98 s | **7.93** | `Freeing drm_logo memory` |

**Power-on to a usable frontend: 7.93 s, against 31.50 s on stock — 4.0x.**

> This table is the **pre-SDR104 baseline**. Raising the boot slot's bus took it
> to **6.87 s** on 2026-08-24 — see [the SD bus
> section](#the-sd-bus-was-capped-in-the-device-tree-2026-08-24) for the phase
> split. The rows above are kept as the reference the change is measured against.

"First frame" is the kernel releasing the bootloader framebuffer as userspace takes
the display — the same event on both systems.

### `rcS` grew, and it *is* dbus

`rcS` was 0.07 s before the Bluetooth work and is 0.20 s now. The split above says
where: **`dbus-daemon --system` is 0.14 s**, the other three phases 0.06 s together.

**Retracted (2026-08-23):** that the bus was "worth ~20 ms", and that the rest was
the first writes to a freshly mounted `/data`. The error was reading
`dbus-daemon`'s `starttime` as when `rcS` reached it. `system.conf` has `<fork/>`,
so that timestamp is the daemonised *child*, after the config parse and socket
bind — comparing it to `rcS-done` measured the tail of dbus's startup.

Two free `mark` calls bracket the block instead, and the `/data` writes cost
**0.01 s**. Deleting the dead ones (`mkdir /data/bluetooth`, `/data/cfg`, read by
nothing) was right, but worth a hundredth of a second, not a tenth.

**The remaining lever:** background `dbus-daemon`. Its only deadline is
`audiomon.elf`, which connects ~0.9 s later and exits if it cannot — 6x the margin
needed. Not done here: it trades a measured 0.14 s for a race that fails silently
in Bluetooth audio.

## The comparison

| phase | stock | BaseOS | |
|---|---|---|---|
| pre-kernel | 4.30 s from NAND | **3.13 s** from SD | −1.17 s |
| kernel → `/init` | 1.61 s | 1.51 s | −0.10 s |
| OS userland → frontend hand-off | **9.88 s** | **0.34 s** | **−9.54 s** |
| **total to hand-off** | **15.79 s** | **4.98 s** | **−10.81 s** |
| NextUI `launch.sh` prologue | **12.45 s** | **0.89 s** | **−11.56 s** |
| `nextui.elf` init → first frame | 3.11 s | 1.98 s | −1.13 s |
| **total to first frame** | **31.50 s** | **7.93 s** | **−23.57 s** |
| total to first frame, with SDR104 | 31.50 s | **6.87 s** | **−24.63 s** |

Essentially the entire vendor userland — `mount -a` over SPI NAND,
`udevadm settle --timeout=30`, then eight serialised `S*` scripts — is gone, and
BaseOS boots from SD *faster than stock does from internal NAND*.

Nothing of ours is left on the critical path except dbus: `adbd` starts at 4.97 and
`ntpd` at 4.94, both after `rcS-done`, and WiFi does not associate until well after
the frame.

### Half the win is not ours, and it is the half we do not understand

**Retracted (2026-08-23):** that the `launch.sh` prologue "is identical on stock, so
it is not a BaseOS cost". It is **0.89 s on BaseOS and 12.45 s on stock** — a bigger
saving than the whole vendor userland we delete, from a script we neither own nor
changed.

That 12.45 s is **unattributed**. Kernel log and syslog are both silent from 15.95 s
to the frame at 31.50 s. Post-hoc on the running device, every candidate was
excluded:

| candidate | measured on stock | |
|---|---|---|
| card I/O | 22 MB/s; the whole 14.4 MB `.system/lib`+`bin` cold in 0.66 s | not it |
| `nextval.elf` ×2 | 0.60 s cold, 0.04 s warm | 1.2 s of 12.45 |
| `amixer scontents` | 0.25 s cold | not it |
| `modetest -M rockchip` | 0.15 s cold | not it |
| `sync`, `killall`, `run_hooks.sh boot.d` | 0.02 s each; no `boot.d`, no `auto.sh` | not it |
| walking the card | `/userdata` (the whole card root on stock) cold in 0.03 s | not it |

File mtimes bracket it without explaining it: `batmon.elf` writes `/tmp/percBat` at
26.4 s, `audiomon.elf` its log at 27.4 s — both ~11 s after starting at 15.94 s — and
`touch /tmp/nextui_exec` lands at 28.4 s. The whole cohort `launch.sh` starts stalls
for the same ~11 s, so something shared rather than one slow step. Attributing it
needs `launch.sh` instrumented across a reboot, i.e. editing a NextUI install.

Two consequences:

1. **The honest BaseOS claim is the hand-off number, 4.98 s against 15.79 s.** The
   4.0x on the frame is what an owner experiences, but 11.6 s of the 23.6 s saved is
   NextUI behaving differently in our environment, not work we removed.
2. **`launch.sh` is the largest block in a BaseOS boot after U-Boot** — 0.89 s
   against `rcS`'s 0.20 s.

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

**Card read rate: 10.9 MB/s.** The kernel drove the same card at SDR25/50 MHz
(`mmc1: new ultra high speed SDR25 SDXC card`, bus speed 50 MHz), which is ~25 MB/s
of headroom — so U-Boot is leaving better than half the available bandwidth unused.
Since 2026-08-24 the kernel runs the slot at SDR104/148.5 MHz and 63 MB/s, so
U-Boot now leaves better than **five sixths** of it unused; the 10.9 MB/s figure
is the vendor binary's own limit and did not move.

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
> desktop intuition says LZ4 should be ~10x faster than gzip, not 0.8x. Both
> numbers stand; the explanation offered for them did not.
>
> **Retracted (2026-08-24):** that "both inflaters are bounded by memory
> bandwidth, not by CPU". Measured on hardware with `dd if=/dev/zero of=/dev/null
> bs=1M count=2000` while DDR sat at its *lowest* rate (324 MHz, idle governor):
> **1.9 GB/s**. The inflates run at 106 and 128 MB/s of output — 15–18x below the
> floor of the mechanism blamed for them, so memory bandwidth cannot be the
> bound. DDR is not the constraint at any point: the FSP table is
> `freq_0 = 1056` MHz and Rockchip's ddrbin trains up to it and stays there
> (`change to: 1056MHz(final freq)` in the mainline serial log), and the kernel
> then *lowers* it to `normal_rate = 780000000`.
>
> What the numbers fit instead is **the CPU clock during U-Boot**. 106 MB/s of
> gzip output is an A55 somewhere near 600 MHz–1 GHz; the parts run to 1992 MHz
> and cpufreq does not probe until ~1.2 s into the kernel. That tax is paid
> across U-Boot's 1.21 s of init, the 0.35 s inflate, and the first second of
> kernel. `cpu@0` carries no `assigned-clock-rates` and no
> `rockchip,cpu-init-rate`, and armclk cannot be raised without moving `vdd_cpu`
> — a ranged `tcs4525` rail U-Boot never programs — so like the 10.9 MB/s read
> this is real, large, and unreachable from the device tree.
>
> The consequence for zstd is the opposite of what was written here: the read
> half (12.99 → 10.82 MB ≈ 0.2 s) is still reliable, and the inflate half is
> **not** capped at 0.05–0.1 s by a bandwidth wall. **Still testable the same
> way**: pad a zstd payload to the raw size and compare. Worth one boot before
> attributing any zstd win.

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

| | H700 (RG40XXV) | my355 (2026-08-23) | |
|---|---|---|---|
| LED → frontend hand-off | **2.96 s** | 4.98 s | we are 2.02 s behind |
| ├ bootloader + kernel + init | 2.04 s | 4.73 s | −2.69 s |
| └ `rcS` + hand-off | 0.92 s | **0.25 s** | **+0.67 s** |
| frontend init → first frame | 4.18 s | **2.95 s** | **+1.23 s** |
| **LED → first frame** | **7.14 s** | **7.93 s** | −0.79 s |
| LED → first frame, with SDR104 | 7.14 s | **6.87 s** | **+0.27 s** |

The two ports land within a second of each other by trading opposite strengths. Our
userland is ~4x leaner and our NextUI start 1.23 s faster (an RK3566 with four A55s
and a 50 MHz card against their A53s); the entire 2.69 s deficit is the
bootloader-and-kernel phase, large enough to swallow both.

Their frontend figure carries our caveat too: it is NextUI's own start, and nobody
has measured what the H700 NextUI does on *stock*. If it behaves like this device's,
4.18 s is a fraction of what an owner sees on the vendor OS.

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
6. **Raise the SD bus above SDR25 — taken, measured at 1.06 s.** Independent of
   (2): it is a kernel-side change and helps everything after `Starting kernel`,
   plus every read at runtime. 22.3 → 63.0 MB/s on the boot card. See below.
7. **Stripping the rootfs libraries — nothing there.** Checked 2026-08-24:
   `libc`, `libSDL2`, `libcrypto`, `libgio`, `libasound` and `libglib` all carry
   zero `.debug_*` sections and no `.symtab` already. The one unstripped ELF on
   the boot path is NextUI's own 150 KB `nextui.elf`, which is not ours. It would
   not have mattered either way: debug sections are non-`ALLOC`, so the dynamic
   linker never faults them in — stripping an mmap'd `.so` saves file size and
   page cache, not load time.

Projected with (2) and (3): pre-kernel **1.3–1.8 s**, power-on to input **5.8–6.3 s**.
Lever (1) claims part of the same ground more cheaply, so they do not add.
Not currently being pursued.


## The SD bus was capped in the device tree (2026-08-24)

The vendor DTB declares this on the boot slot and stops:

```
dwmmc@fe2b0000 {          /* sdmmc0 — mmcblk1, the right-hand slot */
    max-frequency = <150000000>;
    bus-width    = <4>;
    sd-uhs-sdr12;
    sd-uhs-sdr25;         /* and nothing above */
    vqmmc-supply = <&vccio_sd>;
}
```

`sd-uhs-sdr25` pins the bus at 50 MHz. Measured sequential reads: **22.3 MB/s on
the boot card and 22.4 MB/s on the game card** — both exactly at the 50 MHz × 4-bit
ceiling, so **the controller is the limit and neither card is**. The RK3566
`sdmmc0` does SDR104, and `max-frequency` is already set high enough for it.

The usual reason to hesitate does not apply here. UHS needs 1.8 V signalling, and
the rail is already there: `vccio_sd` reads **1 800 000 µV, enabled, 3 users**, and
the card negotiates `mmc1: new ultra high speed SDR25 SDXC card` today. So adding
SDR50/SDR104 is a **clock change, not a voltage change**, and the warm-reboot
hazard that comes with leaving a card at 1.8 V is already the status quo — warm
reboots work.

Slot 1 (`dwmmc@fe2c0000`) is left alone. It shares `vccio_sd` with slot 0, so the
two cannot sit at different I/O voltages, and it currently declares no UHS modes
at all.

Corroboration from outside this project: the Miyoo Flip mainline port runs
`sd-uhs-sdr12/25/50/104` with `max-frequency = <150000000>` on this slot, and
Miyoo themselves shipped SDR104 in `miyoo355_fw_20241119` before capping it to
SDR12/SDR25 in the 2025-05 firmware.

Default is `sdr104` (`MY355_SD_UHS=off|sdr50|sdr104`). Modes negotiate down, so a
card that cannot sustain SDR104 lands on SDR50 or SDR25 by itself.

### Measured on hardware (2026-08-24)

One cold boot, USB unplugged at power-on — the first printk lands at 3.134113 s
against the baseline's 3.134233 s, which is how we know no charge animation is in
these numbers.

The card negotiates the top mode and the controller runs one divider step below
the requested clock:

```
mmc_host mmc1: Bus speed (slot 0) = 148500000Hz (slot req 150000000Hz, div = 0)
mmc1: new ultra high speed SDR104 SDXC card at address 0001
```

| `dd bs=1M count=64`, same offsets both runs | before | after | |
|---|---|---|---|
| `mmcblk1` — boot card, **changed** | 22.3 / 22.2 MB/s | **62.8 / 62.7 / 63.0 MB/s** | **2.8x** |
| `mmcblk2` — game card, **untouched control** | 22.4 / 22.3 MB/s | 22.4 / 22.3 MB/s | — |
| `mmcblk1`, 256 MB sustained | — | 63.2 MB/s | not a cache artefact |

63 MB/s is 85% of the 74.25 MB/s that 148.5 MHz × 4-bit allows. The untouched
second slot holding its 22.4 MB/s is what rules out anything environmental.

`vccio_sd` still reads 1 800 000 µV with 3 users, confirming the prediction that
this moves the clock and not the rail.

### What it bought: 7.93 s → 6.87 s

`Freeing drm_logo memory` and the first printk are both on the power-on-relative
printk clock, so the headline needs no offset at all. The phase split does:
`uptime + 3.302 = power-on` for this boot, from the two `jbd2` anchors (3.301 and
3.303, agreeing to 2 ms).

| phase | 2026-08-23 | SDR104 | Δ |
|---|---|---|---|
| pre-kernel (bootrom → first printk) | 3.13 s | 3.13 s | 0.00 |
| kernel → `Run /init` | 1.51 s | 1.52 s | +0.01 |
| `Run /init` → `rcS` start | 0.08 s | 0.06 s | −0.02 |
| **`rcS`** | 0.20 s | **0.12 s** | **−0.08** |
| ├ of which `dbus-daemon` | 0.14 s | **0.07 s** | −0.07 |
| **hand-off → `nextui.elf` start** | 1.00 s | **0.52 s** | **−0.48** |
| **`nextui.elf` init → first frame** | 1.98 s | **1.52 s** | **−0.46** |
| **power-on → first frame** | **7.93 s** | **6.87 s** | **−1.06** |

**Nothing before the kernel moved, and nothing was expected to** — U-Boot's own
10.9 MB/s read is a property of the vendor binary, unreachable from the device
tree, and the kernel-phase 1.51 s is initcalls rather than I/O. Every hundredth
came from userland, which is where the reads are.

The estimate written here before the boot was 0.3–0.6 s; the outcome is 1.06 s,
so the estimate was low by about 2x. Two reasons. The `/proc/diskstats` figure
that tempered it (~11.5–12 MB/s effective against 22 MB/s sequential) was taken
over a whole session including adb traffic, not over a boot. And the phase that
gained most was the one attributed to NextUI: `nextui.elf` lives on the *game*
card, which we did not touch, but every shared library it links lives in our
rootfs on the boot card — so speeding up `mmcblk1` speeds up NextUI's start
without touching NextUI at all.

**Runtime, not just boot.** The same 2.8x applies to anything read off the boot
card while the device is in use.

**Single cold boot**, like every other figure in this file. The throughput
numbers are three runs each and tight; the phase splits are one boot, so read
the small rows as indicative and the 1.06 s total as solid.

## Where the 9.9 s of stock userland goes

Sequential, all blocking, all before `S60mainui`:

- inittab `sysinit` `mount -a` (ext4 on SPI NAND) + `swapon` — init at 1.61 s uptime,
  `S00mountall`'s `mount-helper` does not start until 5.21 s
- `S10udev`: `udevd -d` + `udevadm trigger` ×2 + **`udevadm settle --timeout=30`**
- `S30dbus`, `S36load_wifi_modules`, `S40bluetooth`, `S40network`, `S41dhcpcd`,
  `S49ntp`, `S50dropbear`, `S50usbdevice`

This is exactly the class of work BaseOS deletes, and deleting it is what the
measured hand-off confirms: **15.79 s → 4.98 s**, 9.54 s of it from this list alone.
(The 2026-08-19 projection was "5.5–6.5 s"; the outcome beat it, because the SD path
also saved 1.17 s of pre-kernel that the projection assumed we would keep.) Reaching
H700-class numbers additionally requires owning U-Boot, which costs another ~2 s.

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
