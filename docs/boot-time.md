# Boot time

Where the time goes from power-on, what each change was worth, and what is left.
Superseded tables and the measurements that led here are in
[history](history.md).

Every figure is one or two cold boots on hardware with **USB unplugged at
power-on** — a cable makes U-Boot run its charge animation first, and that lands
in the arch counter.

## Where a boot goes today

| phase | at power-on | source |
|---|---|---|
| bootrom + DDR + SPL + BL31 | 0.39 s | [boot chain](boot-chain.md) |
| **vendor U-Boot, from the card** | **2.85 s** | first printk |
| kernel → `Run /init` | 3.58 s | dmesg |
| `rcS` | +0.06–0.07 s | `/run/boot-*` |
| **frontend hand-off — `exec updater`** | **3.72–3.74 s** | `/run/boot-frontend-exec` |
| `nextui.elf` start | 4.19–4.23 s | `/proc/<pid>/stat` |
| **first NextUI frame** | **5.72–5.75 s** | `Freeing drm_logo memory` |

Against stock's **15.79 s** to hand-off and **31.50 s** to a first frame, on the
same unit and the same NextUI install. BaseOS boots from SD faster than stock
boots from internal NAND.

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

## Where the pre-kernel time goes

Measured by padding a gzipped kernel payload out to the raw kernel's size, which
holds the inflate work constant while the bytes read change (2026-08-22, when
pre-kernel was 3.14 s):

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
[U-Boot](uboot.md) for what was tried.

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

1. **Ship our own U-Boot — 1.2–1.7 s.** The largest single item in the boot, and
   it needs no NAND write because the card already carries the `uboot`
   partition. **Evaluated and shelved**: mainline U-Boot has no VOP2 driver, so
   a boot logo means writing one — [U-Boot](uboot.md).
2. **zstd for the kernel — 0.2–0.3 s.** Not independent of (1): this 2017.09
   U-Boot has no zstd, and the Android boot path *sniffs* the format, so it
   needs the FIT path a replacement U-Boot would bring.
3. **Shrink what U-Boot reads.** The resource image is already rebuilt at
   442 880 bytes against the stock 943 616. Dropping the charge artwork would
   save another 176 KB, worth ~16 ms.
4. **Tuning the vendor U-Boot from its device tree — tried, 22 ms, dropped.**
   See [U-Boot](uboot.md).

Projected with (1) and (2): pre-kernel 1.3–1.8 s, first frame under 5 s. Not
currently being pursued.

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
