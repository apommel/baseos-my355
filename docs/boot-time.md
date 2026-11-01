# Boot time

Where the time goes from power-on, what each change was worth, and what is left.
Superseded tables and the measurements that led here are in
[history](history.md).

Measured on the vendor 5.10 kernel, which BaseOS booted until 1.3.0. The
mainline kernel's figures, against these, are in
[mainline compatibility](mainline-compat.md): it reaches `Run /init` at 1.01–1.05 s,
hands off at 1.29–1.35 s, shows the logo at 1.27–1.31 s and starts `nextui.elf`
at 2.27–2.35 s (2026-11-01, warm). The initcall list below has no counterpart there;
the SD and `rcS` findings carry over.

Figures are cold boots on hardware with **USB unplugged at power-on** — a
cable makes U-Boot check the charger first, and that lands in
the arch counter — unless marked *warm* (a reboot from BaseOS).

## Where a boot goes today

On the mainline U-Boot path, the default since 0.7.0 ([U-Boot](uboot.md)
Part 3). Three *warm* reboots on 2026-09-21, release U-Boot, with every change
on this page in place; the first frame is from the boots just before the last
two U-Boot changes, which took ~40 ms off. U-Boot's own timings match cold
boots; the kernel phase has only been re-measured warm ([U-Boot](uboot.md),
*Where U-Boot's time goes*). The `Run /init` and hand-off rows are from cold
boots on 2026-10-07, after the top USB port's OHCI came back (+0.05 s).

| phase | at power-on | source |
|---|---|---|
| bootrom + DDR + SPL + BL31 | 0.39 s | [boot chain](boot-chain.md) |
| **mainline U-Boot hands off** | **0.94 s** | bootstage `start_kernel` |
| first printk | 0.99 s | dmesg |
| kernel → `Run /init` | **1.83 s** | dmesg |
| **frontend hand-off — `exec updater`** | **1.99 s** | `/run/boot-frontend-exec` |
| boot logo on the panel | 2.00–2.01 s | `dw_mipi_dsi_bridge_enable` |
| `nextui.elf` start | **2.40–2.42 s** | `/proc/<pid>/stat` |
| **first NextUI frame** | **2.93–2.98 s** | `baseos-frameprobe` (`--diag`) |

`baseos-bootinfo timeline` prints these for any boot; the first frame needs a
`./build.sh --diag` rootfs ([U-Boot](uboot.md), *Measuring it*).

On the vendor U-Boot (as released in 0.6.0):

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

Every figure is seconds from power-on: Rockchip's arch counter, which runs from
SoC reset and which U-Boot's bootstage records use. The kernel's clocks start
later, each at its own point:

* **Mainline.** printk starts at kernel entry, U-Boot's `start_kernel` mark
  (0.62 s), and `/proc/uptime` ~75 ms after it (0.69–0.70 s). `bootclock`
  prints that second offset, read off the counter against
  `CLOCK_MONOTONIC_RAW`. Mainline figures from before 2026-10-31 that came off
  the uptime clock added U-Boot's hand-off instead, so they read ~75 ms early.
* **Vendor kernel.** printk was power-on-relative and uptime started 0.16–0.19 s
  after the first printk. The offset was pinned per boot by writing an uptime
  reading to `/dev/kmsg` and reading its printk timestamp back, or by a
  `jbd2/mmcblk1p*` thread's `starttime` against its `EXT4-fs … mounted` printk.

`rcS` drops breadcrumbs in `/run/boot-*` at each stage, and `frontend-session`
writes `/run/boot-frontend-exec` on its first start; both are `mark()` from
`/usr/share/baseos/log.sh`, uptime readings taken with shell builtins, so they
cost no fork. Process `starttime` (`/proc/<pid>/stat` field 22, USER_HZ = 100)
is on the uptime clock too.

Once the logo is up and the frontend has its hand-off, `rcS` logs one line per
boot to `baseos.log`, on `/data` and the card:

```
Startup: 0.70 s before Linux, 0.69 s Linux to frontend, 1.40 s total; logo on screen at 1.39 s
```

The first three are upstream BaseOS's, computed the same way, so they compare
directly with its H700 figures. It calls the hand-off "menu", although it is
not. `baseos-bootinfo timeline` has the rest:

```
uboot 0.620  printk 0.620  init 1.113  backlight 1.23  handoff 1.41  logo 1.39  nextui 2.35  frame -  (card 88 ms)
```

Compare boots on the same unit, card and cable state, at least three of each,
cold and warm apart.

### What the screen shows

| marker | what it is | at (warm) |
|---|---|---|
| `backlight` | `rcS` lights the backlight; the panel shows nothing yet | 1.13–1.16 s |
| `logo` | `fbsplash` returns: its pan is a blocking commit, so the first modeset and the panel's power-up are behind it, and the logo is on the glass | 1.27–1.31 s |
| `nextui` | `nextui.elf` starts | 2.27–2.35 s |
| `frame` | NextUI's first framebuffer on the panel (`--diag`, `baseos-frameprobe`) | — |

Nothing marks the menu. NextUI's first frame precedes a working menu, so
`frame` is a lower bound for it, not the moment the user can use it.

Filmed on a cold boot (2026-10-31, logo then at 1.71 s), from the work LED
lighting at power-on: backlight at 1.73 s, logo at 2.16 s, NextUI's menu at
3.97 s. The first two are 0.45–0.51 s after their markers, so the LED leads the
counter by about half a second. On the counter, the menu is at ~3.45 s, ~1.1 s
after `nextui.elf` starts.

From `fbsplash`'s start to the logo on the panel is ~0.14 s: the panel's own
waits, a 1 ms reset pulse, 20 ms before the first command and 120 ms after
sleep-out, and ~20 ms of drawing. The logo moves with `Run /init`, so a boot
that hits the SD tuning edge shows it ~30 ms later. Until 2026-10-31 the waits
were 10, 120, 288 and 50 ms, and the logo came at 1.71 s: the init sequence's
`wait=` is hex to the driver, so the tree's `wait=120` and `wait=32` slept 288
and 50 ms.

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
| **Kernel cut to the board** | **~0.3 s** | 27.2 → 16.5 MB Image, 10.4 → 6.6 MiB read: U-Boot hands off at 0.59 s instead of 0.82, and the kernel reaches `/init` ~60 ms sooner ([mainline compat](mainline-compat.md)) |
| **Mainline U-Boot** | **1.8 s** | first printk 2.85 → 0.99 s; step by step under *What is left*, below |
| USB probes held back until `rcS` | ~0.3 s on half the boots | the WiFi chip's probe no longer delays the root mount; below |
| SDR104 tuning in 10° steps | ~0.12 s on half the boots | a tuning read on the edge of the card's bad window waits out a 113 ms timeout in 6 of 22 boots, not 13 of 16; below |
| Tuning data timeout 15 ms (`0046`) | ~0.1 s on half the boots | the read on the bad window's edge waits 15 ms instead of the controller's 112 ms maximum: card init 80–112 ms instead of 80–214, six boots (2026-10-28) |
| EROFS root, GPU library read ahead | ~0.45 s | libmali's 19 MB, faulted in one page at a time by the first NextUI program, are already cached: `baseos-gpu` reads the library at idle I/O priority while boot goes on. First frame 2.57–2.67 s instead of 3.01–3.14 on mali, six boots ([rootfs](rootfs.md), 2026-10-30) |
| `quiet` + `performance` governor | ~0.1 s | full speed from cpufreq's probe until the frontend picks its own |
| `rcS` trimming + clean shutdown | ~30 ms, plus up to 0.2 s of journal replay | see below |

### The kernel phase: three initcalls

`initcall_debug` attributes the kernel phase — 793 initcalls, 1.14 s of accounted
time:

| initcall | cost | skipped? |
|---|---|---|
| `tracer_init_tracefs` | **0.383 s** | **yes** — tracefs is never mounted and nothing reads it |
| `rk3x_i2c_driver_init` | 0.146 s | no — only the PMIC and muic buses are enabled already |
| `ohci_platform_init` | 0.118 s | **no** — the top USB-C port is EHCI `fd800000`, and its OHCI companion takes full- and low-speed devices: gamepads, keyboards, mice. The WiFi chip's companion `usb@fd8c0000` serves nothing and is disabled in the DTB, halving the cost to ~0.06 s ([history](history.md), 2026-10-07) |
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
boots since, root mounted at 2.20–2.22 s (2.07–2.08 s when card init was fast)
and `wlan0` came up every time.

Mainline has no such race, and both went on 2026-10-30: the root mounts at
0.51 s after kernel entry, before the chip enumerates (0.65 s), and its driver
is a module that `S36load_wifi_modules` loads after the hand-off.

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
(10° steps) cut it to 6 of 22, both paths. The
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
(Later `rcS` mounted it once for `baseos-gpu`, `apply` and the settings, and
unmounted it in the background: ~15 ms off `rcS`, spent again when the volume
became exFAT, whose mount reads its allocation bitmap.)

Shutdown mattered for the *next* boot. BusyBox init runs `rcK` before it signals
anything and unmounts nothing itself, and the old `rcK` tried to unmount `/data`
and the card while `adbd` and the frontend still held them — so **every boot
replayed both ext4 journals**, costing 96–137 ms on the root mount and 80–100 ms
on `/data`. `rcK` now stops everything outside its own session (SIGTERM, at most
5 s, SIGKILL), unmounts in reverse mount order and remounts `/` read-only. No
boot has replayed a journal since. The root has since been mounted read-only
([rootfs](rootfs.md)), so its journal cannot need a replay even after a power-off
that skips `rcK`; only `/data` still depends on a clean shutdown.

A FAT card that was once powered off uncleanly keeps mounting as "not properly
unmounted": Linux never clears a dirty flag that was already set at mount, only
`fsck.fat` does. `mount-frontend` now runs it on such a card before mounting it;
checking a clean one costs 1.8 ms ([rootfs](rootfs.md)).

## The mainline boot, step by step

Profiled on 2026-11-01, warm reboots on `gpu=mali`: `initcall_debug` for the
kernel (three boots; it adds ~30 ms), and a probe line per step in NextUI's
`updater`, `my355.sh` and `launch.sh` (three boots, without `initcall_debug`),
each one shell builtin. Times are from kernel entry (0.62 s) for the kernel,
and on the uptime clock for userland, 0.70 s behind power-on.

| kernel time | what |
|---|---|
| 0 → 0.157 s | early init, initcalls before I2C; `of_platform_default_populate_init` 32 ms |
| 0.157 → 0.271 s | **`rk3x_i2c_driver_init`, 114 ms**: the RK817 (111 ms: 44 before its children, regulators 41, RTC 14, power key 6) and `vdd_cpu`, on a 100 kHz bus |
| 0.271 → 0.367 s | the rest; `clk_debug_init` and `rk817_charger_driver_init` 23 ms each |
| 0.367 → 0.444 s | **`deferred_probe_initcall`, 76 ms**: io-domains, display, USB, the boot slot's controller (at 0.41 s), `rk817-sound` |
| 0.426 → 0.499 s | the boot card's init and SDR104 tuning; root waited for from 0.468 s |
| 0.516 s | root mounted, `Run /init` |

591 initcalls sum to 0.40 s. The boot slot defers on io-domains, which defer
on the PMIC's regulators: tried before the I2C bus exists, both wait for
`deferred_probe_initcall`, the first point where the kernel retries, and the
card's 73 ms of init then runs in line instead of alongside the other
initcalls.

| uptime | NextUI's start |
|---|---|
| 0.69 s | hand-off, `exec updater` |
| 0.71 → 0.78 s | `updater`, `my355.sh` (the `/userdata` binds ~25 ms) |
| 0.78 → 0.89 s | `launch.sh`: `mkdir`s ~45 ms, sysfs, daemons, `governor.sh auto` ~35 ms |
| 0.89 → 1.39 s | **the first `nextval.elf wifi`, 0.50 s**; the second, for Bluetooth, takes 0.07 s |
| 1.47 → 1.66 s | **`run_hooks.sh boot.d`, 0.16–0.22 s**: the Status LED pak's `apply.sh` |
| 1.70 s | `tinymix`, then `nextui.elf` starts (2.40 s from power-on) |
| ~2.75 s | the menu, ~1.1 s later (filmed, *What the screen shows*) |

`nextval.elf` reads one key of `system.json`, but links what `nextui.elf`
links: `libmali` (60 MB), SDL2, SDL2_image, SDL2_ttf. The first call loads
them cold; the cost moves to whichever binary runs first (*The `launch.sh`
prologue*, below). `run_hooks.sh` starts hooks in the background, then waits
for them, and the Status LED hook is ~40 forks of `sed`, `tr` and `grep`.

**Levers, ours:**

- **Done: the PMIC's I2C at 400 kHz** (fast mode, which the RK817 and RK8600
  are rated for). Ten warm reboots against five before: `Run /init`
  1.10–1.14 → 1.01–1.05 s, hand-off 1.40–1.43 → 1.29–1.35 s, logo 1.36–1.42 →
  1.27–1.31 s, `nextui.elf` 2.31–2.46 → 2.27–2.35 s. No I2C errors.
- **Tried, not kept: the I2C bus, the RK817 and its regulators registered at
  `subsys_initcall`.** io-domains and the boot slot then probe on the first
  try, the card is found at 0.32 s of kernel time instead of 0.50, and
  `Run /init` is 0.99 s on 14 boots of 15. On top of 400 kHz, ten warm
  reboots: hand-off 1.26–1.30 s, `nextui.elf` 2.20–2.31 s, ~60 ms; but the logo
  1.30–1.34 s, 20–30 ms later, fbsplash now running alongside `baseos-gpu`'s
  `mali_kbase` load and libmali prefetch. It patches three mainline drivers,
  and it moves the power key ahead of the lid at event1, which the lid driver
  linked first in its Makefile puts back. Not worth carrying for 60 ms.
- `gpu=panfrost`, whose libraries load faster: `nextui.elf` ~0.25 s earlier
  ([mainline compatibility](mainline-compat.md)).

**Levers, NextUI's:** `nextval.elf` without the graphics stack, or the two
keys read in shell, which saves its 0.07 s twice and starts `nextui.elf`
sooner, though the libraries still load once; boot hooks that do not hold up
`nextui.elf`, or a Status LED hook in builtins (~0.2 s); the `mkdir`s and
`governor.sh` as builtins (~0.05 s). What `nextui.elf` does in its ~1.1 s to
the menu is not measured: it logs no timestamps.

## What is left

**Our own U-Boot — done, 1.8 s ahead, the default since 0.7.0.** First
printk **0.99 s** against 2.85 s, `Run /init` **1.79–1.80 s** against 3.58 s,
NextUI starting 1.8 s earlier. Its boot logo reaches the panel at 2.00 s
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
| decompression at 1800 MHz, back to 1104 before the hand-off: 347 → 236 ms | 1.83–1.85 s |
| the Flip's own control tree: init after relocation 59 → 36 ms | 1.81–1.82 s |
| **the zstd decoder at `-O2`**, and the release build: 236 → 205 ms | **1.79–1.80 s** |

zstd was first measured 1.60 s *slower* than gzip; the cause was U-Boot's
`-mstrict-align` and `ZSTD_LIB_MINIFY`, not zstd.

What is left of U-Boot's 0.62 s, with the kernel cut to the board, is the
read (0.30 s), decompression (~0.1 s) and init before the boot script
(0.13 s). The order to
take them in is [U-Boot](uboot.md), *Next, in order*.

On the vendor U-Boot only:

- **Shrink what it reads.** The resource image is already rebuilt at 442 880
  bytes against the stock 943 616. Dropping the charge artwork would save
  another 176 KB, worth ~16 ms.
- **Tuning it from its device tree — tried, 22 ms, dropped.** See
  [U-Boot](uboot.md) Part 1.

**Retracted:** "projected with our own U-Boot and zstd: pre-kernel 1.3–1.8 s,
first frame under 5 s". It assumed the vendor U-Boot's 1.21 s was mostly
removable work and priced a zstd decode nobody had run; both were measured
wrong ([U-Boot](uboot.md)). The pre-kernel time reached 0.99 s anyway, by other
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

BaseOS paid the same cost against different storage. The harvested vendor
libraries were in an ext4 rootfs on the boot card, uncompressed, at SDR104 — so
the same work took 0.89 s. Corroboration from within this port: raising that
card from SDR25 to SDR104 moved `nextui.elf`'s start by 0.48 s and its init by
0.46 s, for exactly this reason, even though `nextui.elf` itself lives on the
*other* card ([history](history.md)).

**Retracted:** that this was unattributable, and that `nextval.elf` was excluded
as a candidate by measuring it at "0.60 s cold, 0.04 s warm". Those readings were
taken post-hoc on a running device, where the squashfs pages were already
resident — a warm measurement of the one thing that is only expensive cold.

So of the 25.8 s saved to a first frame, the part BaseOS removes outright is the
9.9 s of vendor userland; the rest is the same work done against faster storage,
which is a consequence of where the harvest lived rather than of deleting
anything. The claim that rests on nothing but our own code is the hand-off
number, **1.99 s against 15.79 s**.
