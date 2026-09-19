# Boot time

Where the time goes from power-on, what each change was worth, and what is left.
Superseded tables and the measurements that led here are in
[history](history.md).

Every figure is one or two cold boots on hardware with **USB unplugged at
power-on** — a cable makes U-Boot run its charge animation first, and that lands
in the arch counter.

## Where a boot goes today

On the mainline U-Boot path, the default since 2026-09-19 and still
experimental ([U-Boot](uboot.md) Part 3). Six warm reboots on 2026-09-19,
after the block cache, 1800 MHz decompression, WiFi and tuning fixes. U-Boot's own timings match
cold boots; the kernel phase has only been re-measured warm ([U-Boot](uboot.md), *Where U-Boot's time goes*).

| phase | at power-on | source |
|---|---|---|
| bootrom + DDR + SPL + BL31 | 0.39 s | [boot chain](boot-chain.md) |
| **mainline U-Boot hands off** | **1.00 s** | bootstage `start_kernel` |
| first printk | 1.05 s | dmesg |
| kernel → `Run /init` | **1.83–1.85 s** | dmesg |
| **frontend hand-off — `exec updater`** | **1.97–2.00 s** | `/run/boot-frontend-exec` |
| boot logo on the panel | 2.03 s | `dw_mipi_dsi_bridge_enable` |
| `nextui.elf` start | **2.43–2.47 s** | `/proc/<pid>/stat` |
| **first NextUI frame** | **2.93–2.98 s** | `baseos-frameprobe` (`MY355_DIAG=1`) |

`baseos-bootinfo timeline` prints these for any boot; the first frame needs a
`MY355_DIAG=1` rootfs ([U-Boot](uboot.md), *Measuring it*).

On the vendor U-Boot (`MY355_UBOOT=vendor`, as released in 0.6.0):

| phase | at power-on | source |
|---|---|---|
| **vendor U-Boot, from the card** | **2.85 s** | first printk |
| kernel → `Run /init` | 3.58 s | dmesg |
| `rcS` | +0.06–0.07 s | `/run/boot-*` |
| **frontend hand-off — `exec updater`** | **3.72–3.74 s** | `/run/boot-frontend-exec` |
| boot logo on the panel | ~1.0 s | drawn by U-Boot |
| `nextui.elf` start | 4.19–4.23 s | `/proc/<pid>/stat` |
| **first NextUI frame** | **5.72–5.75 s** | `Freeing drm_logo memory` |

The two first-frame figures come from different markers, so compare the paths
on the earlier rows. Against stock's **15.79 s** to hand-off and **31.50 s** to
a first frame, on the same unit and the same NextUI install, either path boots
from SD faster than stock boots from internal NAND.

Nothing of ours is left on the critical path except the system bus, which starts
in the background; `adbd`, `ntpd` and WiFi all come up after the hand-off.

## How to measure it

Two clocks, and they disagree. Rockchip's arch counter runs from SoC reset and
U-Boot does not reset it, so **kernel printk timestamps are power-on-relative**.
`/proc/uptime` is not: it starts at timekeeping init, 0.16–0.19 s after the first
printk. Process `starttime` (`/proc/<pid>/stat` field 22, USER_HZ = 100) is on
the uptime clock, so pin the per-boot offset before reading the two together:

* **Direct.** `u=$(cut -d" " -f1 /proc/uptime); echo "probe $u" > /dev/kmsg`,
  then read the printk timestamp back; the difference is the offset. Needed on
  stock, whose squashfs root has no ext4 anchor.
* **By anchor.** A `jbd2/mmcblk1p*` thread's `starttime` against its
  `EXT4-fs … mounted` printk. Two anchors agree to 2 ms.

`rcS` drops breadcrumbs in `/run/boot-*` at each stage, and `frontend-session`
writes `/run/boot-frontend-exec`; both are `mark()` from
`/usr/share/baseos/log.sh`, uptime readings taken with shell builtins, so they
cost no fork.

## Where the pre-kernel time goes, on the vendor U-Boot

Mainline's own breakdown, from its bootstage records, is in [U-Boot](uboot.md)
Part 3. On the vendor U-Boot it was measured by padding a gzipped kernel
payload out to the raw kernel's size, which holds the inflate work constant
while the bytes read change (2026-08-22, when pre-kernel was 3.14 s):

| term | measured | share |
|---|---|---|
| bootrom + DDR + SPL + BL31 | 0.39 s | 12% |
| **U-Boot's own initialisation** | **1.21 s** | 39% |
| reading 13 MB off the card | 1.19 s | 38% |
| gzip inflate | 0.35 s | 11% |

**U-Boot's own init is the single largest item in the whole boot** — AVB/trusty
probing, GPT repair, the charge-animation path, a full DRM bring-up and a SHA1
over the boot image, all before it fetches a byte. Its read runs at **10.9 MB/s**
against the 63 MB/s the kernel gets from the same card, and neither figure is
reachable from the device tree: both are properties of the vendor binary. See
[U-Boot](uboot.md) for what was tried. Mainline hit the same ceiling until its
card clock was found to run at half the rate it reported; the vendor binary most
likely does the same.

## What each change was worth

| change | worth | where |
|---|---|---|
| **Kernel stored gzipped** | **1.82 s** | the payload is 34.9 MiB raw, 11.9 MiB gzipped, and U-Boot reads every byte each boot. `libdeflate-gzip -12` is the same format zlib produces, 486 KB smaller, worth a further 41 ms |
| **SD bus raised to SDR104** | **1.06 s** | the vendor DTB stops at `sd-uhs-sdr25`, pinning the bus at 50 MHz. 22.3 → 63.0 MB/s measured |
| **Three initcalls skipped** | **0.71 s** | `initcall_blacklist=` on the command line; the kernel stays the vendor's |
| `quiet` + `performance` governor | ~0.1 s | full speed from cpufreq's probe until the frontend picks its own |
| `rcS` trimming + clean shutdown | ~30 ms, plus up to 0.2 s of journal replay | see below |

### The kernel phase: three initcalls

`initcall_debug` attributes the kernel phase — 793 initcalls, 1.14 s of accounted
time:

| initcall | cost | skipped? |
|---|---|---|
| `tracer_init_tracefs` | **0.383 s** | **yes** — tracefs is never mounted and nothing reads it |
| `rk3x_i2c_driver_init` | 0.146 s | no — only the PMIC and muic buses are enabled already |
| `ohci_platform_init` | 0.118 s | **yes** — the WiFi/BT chip is high-speed on EHCI and the USB-C port is on xHCI, so the OHCI companions serve nothing |
| `alpu_init` | 0.112 s | **yes** — the anti-clone chip; nothing on BaseOS or NextUI uses it |
| `deferred_probe_initcall` | 0.063 s | — |
| `ehci_platform_init` | 0.033 s | no — the RTL8733BU WiFi/BT chip attaches here |

The vendor kernel has `CONFIG_KALLSYMS=y`, so the stock `initcall_blacklist=`
parameter works and the kernel itself is unchanged. First printk → `Run /init`
went **1.52 s → 0.81 s**. WiFi and Bluetooth both still work; `alpu_init` is the
one that could still surprise someone, since what the stock userland does with
that chip is unknown — take it out of the list first if anything odd shows up.

### The root mount and the WiFi chip

With `rootwait` the kernel mounts root only once the card is there **and** no
driver is mid-probe, polling every 5 ms. The RTL8733BU WiFi chip finishes
enumerating on EHCI within a few ms of the card being ready (both ~2.19 s when
card init takes its usual ~210 ms), and its probe then reads the chip's efuse
over USB for ~0.3 s. Whichever the poll saw first decided the boot: in 11 of 20
boots measured on 2026-09-19, root mounted at ~2.49 s instead of ~2.20 s, and
everything after it moved by the same amount.

`usbcore.authorized_default=0` keeps USB drivers from probing during kernel
init, and `rcS` authorizes the devices in the background, which runs the WiFi
probe beside userspace. A device still enumerating when `rcS` changes the
default was allocated under the old one, so `rcS` sweeps for a second. In 12
boots since, root mounted at 2.20–2.22 s (2.07–2.08 s when card init was fast) and
`wlan0` came up every time. `/run/boot-usb` records the last authorization.

### The SD bus

The vendor DTB declares `sd-uhs-sdr12`/`sdr25` on the boot slot and stops, which
pins the bus at 50 MHz. Both cards measured 22.3 MB/s — exactly the SDR25
ceiling — so the controller was the limit, not the media. The RK3566 `sdmmc0`
does SDR104, `max-frequency` is already 150 MHz, and `vccio_sd` already sits at
1.8 V because the card negotiates SDR25 today, so adding the flags is a **clock
change, not a voltage change**.

Measured after: `mmc1: new ultra high speed SDR104 SDXC card`, 62.8–63.0 MB/s on
the boot card against an untouched 22.4 MB/s on the game card in the other slot,
which is what rules out anything environmental. It is worth 1.06 s of boot and
the same 2.8x on everything read at runtime. The gain shows up largely in
NextUI's own start, because every shared library it links lives in our rootfs on
the boot card.

**Tuning.** SDR104 makes the kernel tune the sample phase: it steps from 0° to
270°, sends a tuning read at each step and skips 20° after a bad one. A read on
the edge of the card's bad window (60–105° on this card) can get no data at all
and wait out the controller's ~113 ms data timeout, which is most of the
difference between card init at ~77 ms and at ~200 ms. At the vendor default of
1° steps the edge was hit in 13 of 16 boots; `rockchip,desired-num-phases = 36`
(10° steps, `rkbootimg.SD_TUNING_PHASES`) cut it to 6 of 22, both paths. The
timeout itself is in the kernel's tuning code, out of reach. A fixed phase
(`rockchip,use-v2-tuning`) would skip tuning altogether but suits only the card
it was chosen for. All warm reboots, one card.

Slot 1 **cannot follow**: its pins are GPIO2_A3–B0, in I/O domain `vccio4` on a
fixed 3.3 V rail. Tried on 2026-09-16 — the card accepted the 1.8 V switch, the
host could not follow, and `mmcblk2` never appeared. It stays at 50 MHz.

Corroboration from outside this project: the Miyoo Flip mainline port runs
`sd-uhs-sdr12/25/50/104` with `max-frequency = <150000000>` on this slot, and
Miyoo themselves shipped SDR104 in `miyoo355_fw_20241119` before capping it in
the 2025-05 firmware.

### `rcS` and the shutdown

Four changes took `rcS` from 0.16 s to **0.06 s**: the two update hooks only run
when `/data/update/state` exists (a builtin test, against 8 ms to start a script
that would do nothing), `dbus-daemon --system` moved to the background with
`frontend-session` waiting on its socket before handing off, the random seed
moved to the background, and the machine-id is copied with shell builtins.

`baseos-update apply` is now the largest item left in `rcS`, at 20–30 ms: it
mounts this card's own FAT volume read-only on every boot to look for a payload.

Shutdown mattered for the *next* boot. BusyBox init runs `rcK` before it signals
anything and unmounts nothing itself, and the old `rcK` tried to unmount `/data`
and the card while `adbd` and the frontend still held them — so **every boot
replayed both ext4 journals**, costing 96–137 ms on the root mount and 80–100 ms
on `/data`. `rcK` now stops everything outside its own session (SIGTERM, at most
1 s, SIGKILL), unmounts in reverse mount order and remounts `/` read-only. No
boot has replayed a journal since. `rcS` also remounts `/` `noatime`, which the
kernel mounts `relatime`.

A FAT card that was once powered off uncleanly keeps mounting as "not properly
unmounted": Linux never clears a dirty flag that was already set at mount, only
`fsck.fat` does, and BaseOS ships none.

## What is left

**Our own U-Boot — done, 1.7 s ahead, the default since 2026-09-19.** First
printk **1.05 s** against 2.85 s, `Run /init` **1.83–1.85 s** against 3.58 s,
NextUI starting 1.7 s earlier. Its boot logo reaches the panel at 2.03 s
against ~1.0 s. What got it there, each step measured on its own boots (cold
up to the data cache, warm after):

| step | `Run /init` |
|---|---|
| first build, CPU left at 816 MHz | 3.65–3.67 s |
| CPU handed over at 1104 MHz, as the vendor does | 3.44 s |
| zstd kernel, decoded in 347 ms against gzip's 447 | 3.24 s |
| SD card actually at 50 MHz: mainline's RK3568 clock driver ran it at 25 | 2.66 s |
| data cache on before relocation: early init 570 → 40 ms | 2.09–2.12 s |
| block cache holding the GPT: `mmc dev 1` 202 → 53 ms | 1.95–1.98 s |
| **decompression at 1800 MHz**, back to 1104 before the hand-off: 347 → 236 ms | **1.83–1.85 s** |

zstd was first measured 1.60 s *slower* than gzip; the cause was U-Boot's
`-mstrict-align` and `ZSTD_LIB_MINIFY`, not zstd.

What is left of U-Boot's 1.00 s is the read (0.53 s at 23.8 MB/s),
decompression (0.24 s) and init before the boot script (0.14 s). The order to take them in is
[U-Boot](uboot.md), *Next, in order*.

On the vendor U-Boot only:

- **Shrink what it reads.** The resource image is already rebuilt at 442 880
  bytes against the stock 943 616. Dropping the charge artwork would save
  another 176 KB, worth ~16 ms.
- **Tuning it from its device tree — tried, 22 ms, dropped.** See
  [U-Boot](uboot.md) Part 1.

**Retracted:** "projected with our own U-Boot and zstd: pre-kernel 1.3–1.8 s,
first frame under 5 s". It assumed the vendor U-Boot's 1.21 s was mostly
removable work and priced a zstd decode nobody had run; both were measured
wrong ([U-Boot](uboot.md)). The pre-kernel time reached 1.05 s anyway, by other
means.

## Stock, for comparison

`uptime + 4.49 = seconds from power-on`, measured 2026-08-23:

| phase | duration | at power-on |
|---|---|---|
| bootrom → U-Boot, **from NAND** | 4.30 s | 4.30 |
| kernel → `/sbin/init` | 1.61 s | 5.91 |
| init → `S01syslogd` | 4.27 s | 10.18 |
| `S10udev` … `S50usbdevice` | 5.23 s | 15.41 |
| `S60mainui` → `runmiyoo.sh` → `updater` → `my355.sh` | 0.24 s | 15.79 |
| **frontend hand-off** | | **15.79** |
| NextUI `launch.sh` prologue | **12.45 s** | 28.39 |
| `nextui.elf` init → first frame | 3.11 s | **31.50** |

The 9.9 s of vendor userland is the part BaseOS deletes: `mount -a` over SPI
NAND, `udevadm settle --timeout=30`, then eight serialised `S*` scripts.

### The `launch.sh` prologue: 12.45 s on stock, 0.89 s here

That single line is a bigger saving than the whole vendor userland BaseOS
deletes, from a script we neither own nor changed. Instrumented on stock, it is
**the cost of loading the vendor graphics stack off SPI NAND**.

`launch.sh` starts a cohort — `miyoo_inputd`, `keymon`, `batmon`, `audiomon`,
then `nextval.elf` — and nearly all of the 12.45 s lands in `nextval.elf`. Not
because that binary is slow, but because it runs **first**, so it is the one that
faults in SDL2, `libmali` and the rest of the shared stack. On stock those live
in `/usr/lib` on the **squashfs in SPI NAND**: a slow read, decompressed block by
block, with the whole cohort blocked behind the same misses. That is why the
mtimes showed every one of them stalling for the same ~11 s, and why swapping
which binary goes first would just move the bill.

BaseOS pays the same cost against different storage. The harvested vendor
libraries are in our ext4 rootfs on the boot card, uncompressed, at SDR104 — so
the same work takes 0.89 s. Corroboration from within this port: raising that
card from SDR25 to SDR104 moved `nextui.elf`'s start by 0.48 s and its init by
0.46 s, for exactly this reason, even though `nextui.elf` itself lives on the
*other* card ([history](history.md)).

**Retracted:** that this was unattributable, and that `nextval.elf` was excluded
as a candidate by measuring it at "0.60 s cold, 0.04 s warm". Those readings were
taken post-hoc on a running device, where the squashfs pages were already
resident — a warm measurement of the one thing that is only expensive cold.

So of the 25.8 s saved to a first frame, the part BaseOS removes outright is the
9.9 s of vendor userland; the rest is the same work done against faster storage,
which is a consequence of where the harvest lives rather than of deleting
anything. The claim that rests on nothing but our own code is the hand-off
number, **3.73 s against 15.79 s**.
