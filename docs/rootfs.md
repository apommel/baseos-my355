# The rootfs

How the BaseOS userland is assembled, and what it must reproduce so NextUI
behaves exactly as it does on stock.

## Pipeline

```
./fetch-prepared.sh  published bundle → work/my355/prepared/
./prepare-stock.sh   NAND backup      → the same four files:
                             uboot.img, boot.img, stock-harvest.tar, source.json
./build-rootfs.sh    harvest + overlay + static BusyBox → rootfs.tar
./build-image.sh     prepared + rootfs → baseos-my355.img
```

Both routes produce byte-identical inputs, and `source.json` — which travels in
git, not inside the bundle — is what every build checks them against. The
harvest's paths are checked against `manifest/harvest.list` as well: its hash
would still match an old tar after the list changes, so a list edit that was
never re-prepared fails the build instead of shipping without the new path.

## Sources

Four, applied in order so each can override the last:

1. **The merged-`/usr` skeleton** the harvest assumes: `bin`, `sbin`, `lib`,
   `lib64` are symlinks and real content lives under `/usr`, exactly as the
   vendor rootfs is laid out.
2. **Static BusyBox** (Alpine `busybox-static`) plus its applet symlinks — `rcS`
   calls `/bin/mount` and friends by path. `build-rootfs.sh` prints the applet
   count at the end of a build.
3. **The stock harvest** — the allowlisted paths from `mtd3` named in
   `manifest/harvest.list`; `source.json` records how many and how large.
4. **`overlay/`** — `init`, `inittab`, `rcS`, `rcK`, the frontend session,
   the USB gadget. Committed executable, so `cp -a` is all the build does.

`mtd3` is **squashfs**, so preparation uses `unsquashfs`. It is unpacked to a
container-local scratch directory, never a bind mount: the stock rootfs contains
both `/mnt/sdcard` and `/mnt/SDCARD`, which collide on a case-insensitive host
filesystem such as macOS.

## The harvest is measured, not guessed

`manifest/harvest.list` was derived by reading `/proc/<pid>/maps` across the
whole running NextUI stack on hardware — every entry was observed mapped, or is
needed by something that was.

Two findings keep it small:

- NextUI ships its own SDL, tinyalsa and sqlite in `.system/my355/lib`.
- `miyoo_inputd` does not link `/usr/miyoo/lib`; those three vendor libraries
  (`libgamename`, `libshmvar`, `libtmenu`) are referenced by `LD_LIBRARY_PATH`
  but never loaded.

**Preparation verifies the closure.** Every `DT_NEEDED` of every harvested ELF
must resolve inside the harvest or the build fails — which is what turns an
allowlist into a proven closed set. Runtime-confirmed on hardware:
`wpa_supplicant v2.9` and `dbus-daemon 1.12.20` both execute. What it cannot
verify is below.

### What a maps reading cannot see

`/proc/<pid>/maps` shows what was mapped at that moment, and the closure check
walks `DT_NEEDED`. Neither sees a `dlopen`, or a `system()`/`popen()` call, so
the list grows as more of the stack is exercised:

| entry | reached by | why it is needed |
|---|---|---|
| `libasound.so.2` | SDL2 `dlopen` | SDL2 has three audio drivers compiled in — `alsa`, `disk`, `dummy`. Without it every emulator falls back to `dummy` and runs silent. NextUI's bundled `libtinyalsa` drives the mixer only, never playback. The frontend menu opens no PCM device, so it never appears in `nextui.elf`'s maps; `minarch` opens one per game |
| `/usr/share/alsa` | alsa-lib | required to resolve a PCM name |
| `amixer` | `libmsettings` | the Bluetooth A2DP path |
| `curl`, `libcurl.so.4` | `common/http.c` `popen` | every HTTP request the frontend makes |
| `/etc/ssl/certs`, `/usr/share/ca-certificates` | curl | see TLS below |
| `/usr/share/zoneinfo` | `PLAT_initTimezones` | parses `zone.tab` to build the Settings list; absent, `PLAT_getCurrentTimezone()` returns `NULL` for any stored index |
| BlueZ + bluealsa | `bt_init.sh` `system()` | see Bluetooth below |
| `alsa-lib/*_bluealsa.so` | alsa-lib `dlopen` | `audiomon` writes an `.asoundrc` naming `type bluealsa` for both pcm and ctl |
| `modetest` | `libmsettings` `system()` | the panel's DRM `contrast` and `saturation` properties are set with `modetest -M rockchip -w 179:<prop>:<0-100>`; brightness is sysfs PWM and worked without it |

Two layout notes. Zone files live in `posix/` and the top-level names symlink
into it, so only `right/` can be dropped. `/etc/localtime` is a symlink to
`/userdata/localtime` — stock's target, which `PLAT_setCurrentTimezone()` copies
into and NextUI's `my355.sh` bind-mounts onto the frontend card.

### TLS needs two things

Both failures look identical from the UI — link up, ping and DNS fine, every
request fails — and each survives fixing the other.

**The certificate store.** `/etc/ssl/certs` is two layers of symlinks:
`002c0b4f.0` → `GlobalSign_Root_R46.pem` →
`../../../usr/share/ca-certificates/mozilla/GlobalSign_Root_R46.crt`. Harvesting
`/etc/ssl/certs` alone leaves 254 dangling links and
`unable to get local issuer certificate`. A pak bundling its own libcurl does not
escape this.

**The clock.** Certificates are validated against system time, so a stale clock
fails every HTTPS request with `certificate is not yet valid` — including for a
pak shipping its own CA bundle. An unset Flip RTC reads **2017-08-04**. `rcS` now
restores the clock from the RTC and starts `S49ntp`, both backgrounded. Starting
`ntpd` before the network exists is safe: BusyBox `ntpd` retries an unresolvable
peer instead of exiting, steps the full nine-year offset in one go, and its `-S`
hook writes the result back to the RTC so the next boot starts sane.

### Version identity

`/etc/baseos-release` carries `BASEOS_TARGET` and the panel rotation `fbsplash`
reads; `build-rootfs.sh` appends `BASEOS_VERSION` from `VERSION` and a
`git describe` `BASEOS_BUILD`. An uncommitted
tree's `-dirty` id gets a UTC timestamp appended, so two such builds never share
an id: a card skips a same-version payload whose id matches its own. The id goes
to `work/my355/build-id`, which `build-update.sh` puts in the manifest.

`/usr/miyoo/version` is written from the same variable and reads
`BaseOS <version>`. It exists because `PLAT_getOsVersionInfo()` reads that path for the About screen
and passes the buffer to `getFile()`, which leaves it untouched when the file is
missing — so the caller's uninitialised 128-byte stack buffer is what Settings
renders, and what `settings.cpp` logs at start-up. That is the garbage in the
"Stock OS version" row, and the crash when the bytes contain no terminator.

## Boot path

```
kernel  --init=/init-->  /init  --exec-->  busybox init  --sysinit-->  /etc/init.d/rcS
                                                         --respawn-->  /sbin/frontend-session
```

`init=/init` is not optional; see [the card](card.md).

`rcS` runs in **0.06 s**, with `dbus-daemon --system` started in the background
(see [boot time](boot-time.md)). It stays short because the vendor kernel does
the work an init script would otherwise do: `devtmpfs` is mounted by the kernel,
and Mali, WiFi and the panel are built in, so nothing is `insmod`ed here
([hardware](hardware.md)).

What it does do: tmpfs skeleton, `/data` (`mmcblk1p4`), machine-id, entropy seed,
**loopback**, the first-boot card expansion, the frontend card, any pending system
update, and the USB gadget in the background. Of the two update hooks,
`baseos-update boot-check` after `/data` only runs when a trial is pending (a
builtin file test). `apply` after the card mount costs a failed glob plus a
read-only mount of this card's FAT partition, about 20–30 ms
([the card](card.md)).

`rcK` does the shutdown work busybox init leaves out. It stops every other
process (SIGTERM, at most 1 s, SIGKILL), unmounts the frontend's binds, the card
and `/data`, and remounts `/` read-only. Without that, both ext4 journals replay
on every boot.

### One log

Everything that logs writes the same file, through `log()` in
`/usr/share/baseos/log.sh`: `rcS`, `rcK`, `expand-storage`, `baseos-update`,
`usb-gadget-adb` and `frontend-session`. Each line carries the script's own name,
so one file reads as the chronology of a boot:

```
0.47 rcS: ...
0.52 expand-storage: expanded to fill the card
1.57 usb-gadget-adb: start
1.85 usb-gadget-adb: UDC bound -> fcc00000.dwc3
3.72 frontend-session: exec /mnt/SDCARD/.tmp_update/updater
```

The file is `/data/baseos.log`, copied line for line to `/mnt/SDCARD/baseos.log`
when a frontend card is mounted — `/data` is ext4 and needs the trick in
[diagnostics](diagnostics.md) to read, while the card copy opens on any computer.
Both **append across boots**, as upstream BaseOS does: `rcS`'s boot record is
what delimits one boot from the next, and the whole history stays readable. That
also keeps the `rcS` critical path free of the two `mv` forks an every-boot
rotation would cost — 1.5 ms on `/data` and 3.0 ms on the card's FAT, measured on
the device. About 1.1 KB per boot.

The helper uses shell builtins only, including the `/proc/mounts` scan that
decides where a line goes: its callers are on the boot path, where a fork costs
about 8 ms. It writes **on the mounts, not the directories**, because writing
through an unmounted mount point would leave a stray file on the root filesystem
— which at shutdown is already going read-only. `mark()` lives there too, for the
`/run/boot-*` uptime breadcrumbs the [boot-time](boot-time.md) measurements read
back.

Two things bypass `log()` and land on `/data` only, never on the card. `adbd`'s
own output, because it runs for the whole session and the card copy is on
removable FAT. And the raw stderr of the tools the scripts drive — `dd`,
`gunzip`, `gptslot`, `mkfs.vfat`, `unzip` — which is redirected straight at
`$BASEOS_LOG`, so it carries no tag and is only there for the failure it
describes. The card copy stays tagged throughout, which is the one a user reads.

### Loopback is load-bearing

`adbd` binds its smartsocket on `127.0.0.1:5037` during start-up and treats failure
as fatal — it never reaches `usb_ffs_init`, so no endpoints appear and the UDC bind
silently does nothing. Without `lo` there is no adb. This is loopback-only and
unrelated to the network listener disabled above. Stock has `lo` up; nothing else
in BaseOS needs it.

## adb over USB

`usb-gadget-adb` reproduces the configfs gadget stock builds with its
700-line vendor `usbdevice` script, reduced to what adb needs. The shape was read
off a running stock unit, not derived from the script:

```
gadget    rockchip      idVendor 0x2207  idProduct 0x0006  bcdDevice 0x0310
function  ffs.adb       functionfs at /dev/usb-ffs/adb, -o uid=2000,gid=2000
config    b.1 "adb"
UDC       fcc00000.dwc3
env       ADB_TCP_PORT unset  (see below — adb is USB-only)
```

**No network adb.** `adbd` binds `0.0.0.0:$ADB_TCP_PORT` as an unauthenticated
root shell whenever that parses as a positive int — stock exposes 5555 once WiFi
is up. The compiled default is the empty string, so leaving it unset is enough.
(Upstream patches `adb.c` for the same result; the harvested adbd needs only the
unset variable.)

**Ordering is load-bearing**: `adbd` must be running and have written its
descriptors before the UDC is bound, or the host sees a gadget with no endpoints.
A successful run logs:

```
1.57 usb-gadget-adb: start
1.60 usb-gadget-adb: gadget created
1.62 usb-gadget-adb: functionfs mounted: ep0
1.62 usb-gadget-adb: adbd started
1.84 usb-gadget-adb: after wait: ep0 ep1 ep2
1.85 usb-gadget-adb: UDC bound -> fcc00000.dwc3
```

It never blocks boot: no `set -e`, every failure path returns quietly, and
`/etc/init.d/dev` backgrounds it. Because it must fail quietly, it **logs** instead
— the only way to diagnose it on a device with no console.

> **A cable is not required before power-on — verified.** RK3566 uses dwc3 with
> plain configfs and VBUS detection, and we only ever write `UDC`. Hot-plugging
> after boot works, which is also how a clean boot time gets measured.

## NextUI compatibility

The contract: starting NextUI from BaseOS must behave exactly as from stock,
differing only in which slot the card is in. NextUI itself is slot-agnostic —
nothing in `my355.sh` or `MinUI.pak/launch.sh` names a block device — so the whole
burden is in reproducing what stock's `runmiyoo.sh` sets up.

`mount-frontend` mounts the frontend card at `/mnt/SDCARD`, and
`/mnt/sdcard` is a symlink for the lowercase path stock uses. BaseOS takes the
right slot because it is the only slot the SPL can boot from, so the frontend card
normally goes in the **left** slot (`mmcblk2p1`); this card's own FAT partition
(`mmcblk1p5`) is the single-card fallback.

The choice is by content, not by slot: each candidate is mounted in turn, left
slot first, and kept only if it carries a frontend (`.tmp_update/updater`,
`MinUI.zip`, or `miyoo355/app/.tmp_update`) — otherwise an empty or ROM-only card
in the left slot would hide a frontend installed on the boot card. If neither
qualifies the left slot still wins. It costs one extra `mount`/`umount` pair, ~10 ms.

`rcS` and `frontend-session` both call it: `rcS` is `::sysinit:` and runs once, the
session is `::respawn:`, so only the session can pick up a card inserted after
boot. The kernel needs no help; neither `dwmmc` node sets `broken-cd`, and
`/dev` is devtmpfs.

A retry alone is not enough. With the left slot empty at boot `rcS` mounts the
fallback, leaving `/mnt/SDCARD` occupied and a later card nowhere to go, so when
`mmcblk2p1` turns up the session releases it — including the `/userdata` binds a
frontend that ran from it left behind — and lets `mount-frontend` choose again. Safe only there: no frontend is running,
before or after. A card already mounted from the left slot is never disturbed.

`frontend-session` starts by ending any open update trial — a session starting is
what confirms a new slot ([the card](card.md)) — then stages
`.tmp_update` on a fresh card (below) and execs `.tmp_update/updater`. **Not**
`launch.sh`: the updater installs `MinUI.zip`/`*.pakz`, so updates behave the same.

### The shared stock hook

That hand-off is the whole contract. Since NextUI `da3165de` (2026-09-15) its
stock hook is aligned with spruceOS's: `runmiyoo.sh` only waits for the card,
swaps a left-slot card carrying `.tmp_update/updater` onto `/mnt/sdcard`, and runs
that `updater`. Everything else lives on the card, in `.tmp_update/my355.sh`:

| in NextUI's `my355.sh` | why | on BaseOS |
|---|---|---|
| `$SDCARD/.userdata/my355/userdata` skeleton and first-run `system.json` | decides volume, brightness, keymap on first launch | runs as on stock; the image ships an empty `/userdata` to bind onto |
| `mount --bind` it onto `/userdata` | `wpa_supplicant.conf`, `system.json` and BT pairings live there; the internal userdata partition corrupts | same |
| `mount --bind /run/bluetooth_fix` over `/userdata/bluetooth` | BlueZ names pairing files by MAC, which FAT32 rejects | same |
| "Please use the right SD slot" when `/mnt/sdcard` is `mmcblk2*` | a stock limitation | not triggered, but only because `/proc/mounts` lists `/mnt/SDCARD`; `/mnt/sdcard` is a symlink here. BaseOS must keep the card on `/mnt/SDCARD`: mounting it at the lowercase path would power off every boot |

So BaseOS writes nothing to the card beyond staging `.tmp_update`, and anything
before the hand-off that touches `/userdata` sees the empty root directory —
`S36load_wifi_modules` refuses to seed it for that reason.

Starting is not running: a spruceOS card would be mounted and its `updater`
executed, but whether spruceOS finds the stock userland it expects in the harvest
has not been checked.

### Installing onto a fresh card

`.tmp_update` is not at the top of the base zip. It sits inside `miyoo355/app/`,
and on stock it is NextUI's own `my355.sh` that copies it up:

```
runmiyoo.sh   CUSTOMER_DIR=/media/sdcard{0,1}/miyoo355/   (sdcard1 wins if present)
  -> $CUSTOMER_DIR/app/MainUI      shell shim -> my355.sh
     -> app/my355.sh               init.sh ; cp -rf .tmp_update up ; rm -rf miyoo355 ; updater
```

`init.sh` there is the NAND hook — unsquash `/dev/mtd3ro`, swap
`/usr/miyoo/bin/runmiyoo.sh` for NextUI's, `flashcp` it back — which is exactly
what BaseOS replaces. It runs every time and replaces an installed hook only
when its `PAYLOAD_VERSION` is newer, since the hook is shared with spruceOS. The `cp` is not, and dropping it with the rest meant a
card that had never booted on stock had no `updater` to hand off to.
`frontend-session` now does that copy, and the `rm -rf miyoo355` after it, leaving
the card in the state a stock install leaves it. Everything downstream is
NextUI's, unmodified: `updater` re-derives the platform and runs
`.tmp_update/my355.sh`, whose `show2.elf` splash works here because it needs only
SDL2/`_image`/`_ttf` — harvested — and embeds its font.

Two departures from the vendor script. `miyoo355/` is removed only after the
staged `updater` is confirmed present, so a failed copy leaves the card still
installable on stock. And if `miyoo355/` is gone but `MinUI.zip` is there, the
same `.tmp_update` is unzipped out of the zip — a dead end on stock, but the only
route on a card that has one and no customer directory.

**`miyoo355` only.** Stock's `runmiyoo.sh` names a card directory in one place,
the `CUSTOMER_DIR` lookup above, and both candidates are `miyoo355/`. The base zip
used to also carry `miyoo/`, the historic MinUI directory for the Miyoo Mini and
A30, as the source NextUI's `makefile` copied `miyoo355/` from; since `da3165de`
it ships `miyoo355/` and `trimui/` only.

### Init-script contracts

NextUI's my355 build names four init scripts — from `etc/wifi/wifi_init.sh`,
`etc/bluetooth/bt_init.sh` and `platform.c`. They live on the frontend card, so
BaseOS has to answer to the names; the contents are ours. Stock's `rcS` runs
`for i in /etc/init.d/S??*`, so on stock all four also start at boot.

| script | BaseOS | at boot? |
|---|---|---|
| `S36load_wifi_modules` | seeds `/userdata/cfg/wpa_supplicant.conf`; no modules, the driver is built into this kernel (`lsmod` is empty, yet `wlan0` exists and `RTW_CMD_THREAD` runs) | no — the frontend calls it when WiFi goes on |
| `S41dhcpcd` | BusyBox `udhcpc`, not the vendor `dhcpcd` | no — the frontend calls it when WiFi goes on |
| `S49ntp` | BusyBox `ntpd`, not stock's 757 KB one | yes — TLS depends on the clock |
| `S40bluetooth` | `bluetoothd`, after bringing the system bus up | no — the frontend calls it when Bluetooth goes on |

Only `S49ntp` runs at boot, and backgrounded. The others stay frontend-driven
because `wifi_init.sh` and `bt_init.sh` call them anyway and boot must not grow.

**The supplicant config.** `S36` looks like the one script with nothing to do,
and was a bare `exit 0` until a user reported no WiFi networks at all on a fresh
install. Stock's `S36` loads modules *and* copies `/etc/wpa_supplicant.conf` into
`/userdata/cfg/` when absent; `wifi_init.sh` then starts `wpa_supplicant -c` on
that path, and wpa_supplicant **exits 255** rather than starting when the file is
missing. A card that had never booted stock therefore ran no supplicant, and
`wpa_cli scan` had nothing to answer NextUI: an empty list with the chip
enumerated, `wlan0` up and rfkill clear. It read as a radio fault and was a
missing file — one the reporter fixed unknowingly by booting stock to test, which
ran the real `S36`. BaseOS ships its own template and seeds it the same way,
minus stock's placeholder `network={ ssid="SSID" }` stanza, which cannot
associate and which NextUI would list as a saved network.

**DHCP.** Stock's `dhcpcd` 9.4.1 would mean a 368 KB binary, its hook and share
directories and a privsep user. BusyBox `udhcpc` is already in the image and needs
only an event script: `usr/share/udhcpc/default.script` sets the address,
default route and
`/run/resolv.conf`, with `/etc/resolv.conf` a baked symlink to it.

Two details. `wifi_init.sh` starts DHCP *before* `wpa_supplicant`, so `udhcpc`
runs with `-b` rather than blocking the WiFi toggle while `wlan0` has no carrier.
And stock's `S41dhcpcd` wraps the daemon in `start-stop-daemon`, which Alpine's
`busybox-static` does not build, so the script invokes `udhcpc` directly.

Without any of this `wpa_supplicant` still associates and the frontend still
reports "connected" — it reads carrier, not a lease — while `wlan0` holds only a
link-local IPv6 address, with no IPv4 route and no resolver.

### Bluetooth

NextUI drives the whole sequence from its own `etc/bluetooth/bt_init.sh` on the
card: `insmod /lib/modules/rtk_btusb.ko`, `rfkill.elf unblock`, wait for
`/sys/class/bluetooth/hci0`, `/etc/init.d/S40bluetooth start`, then
`bluealsa -p a2dp-source` and a run of `bluetoothctl` calls. BaseOS supplies the
parts that script expects to find in the OS:

| | |
|---|---|
| `rtk_btusb.ko` | the transport. 2.3 MB, and it requests `rtl8733bu_fw` / `rtl8733bu_config` by name — both at `/lib/firmware`, both harvested. The empty `rtlbt/` directory beside them is unused |
| `bluetoothd`, `bluetoothctl`, `bluealsa`, `hciconfig`, `hcitool` | plus `libbluetooth`, `libsbc`, `libmpg123` and the glib stack. `hcitool` is not optional: `PLAT_bluetoothConnected()` greps `hcitool con` for an `ACL` line, and its `popen` fallback only fires when `popen` itself fails — a missing binary just reads as "not connected", so the status-bar icon never appears |
| `S40bluetooth` | ours. Stock's wraps `bluetoothd` in `start-stop-daemon`, absent from Alpine's `busybox-static`. It keeps a `pidof dbus-daemon` guard so it still works if the bus is somehow down, though `rcS` starts it. **BlueZ 5 never forks**: run it in the foreground and the script blocks, `bt_init.sh` blocks behind it and Settings hangs on "Enabling Bluetooth…" — so `setsid … -n &`, which is what `start-stop-daemon -b` was doing |
| `/etc/bluetooth`, `/etc/dbus-1/system.d/blue*.conf` | already covered by the harvested `/etc/dbus-1` |
| the `dbus` user | the harvested `system.conf` drops privileges to it, so `passwd`, `group` and `shadow` must all name it `dbus`; an Ubuntu-style `messagebus` makes `dbus-daemon --system` refuse to start |
| `libasound_module_{pcm,ctl}_bluealsa.so` | the rest of `alsa-lib/` is unreferenced — nothing sets `defaults.pcm.rate_converter`, so `type plug` uses the built-in linear one |

`rcS` starts the system bus, as stock's `S30dbus` does. This is not for BlueZ's
benefit — NextUI's `audiomon.elf` connects to it at frontend start whether or not
Bluetooth is ever used, and **exits** if it cannot, which leaves nothing to write
`.asoundrc` and so no route to bluealsa. `rcS` starts it in the background, and
`frontend-session` waits for `/run/dbus/system_bus_socket` (at most 1 s) before
handing off, so there is no race with the frontend.

`rcS` also adds two links: `/var/lib/dbus/machine-id` → `/run`, and
`/var/lib/bluetooth` → `/userdata/bluetooth`, which is stock's arrangement.
NextUI's `my355.sh` shadows that directory with a tmpfs because FAT32
rejects BlueZ's MAC-named files — so as on stock, pairings do not survive a
reboot.

Exercised on BaseOS: `bt_init.sh` loads `rtk_btusb` from the harvested
`/lib/modules`, `hci0` comes up with the same BD address as stock (so the
firmware harvest is right), `S40bluetooth start` returns in 0.05 s,
`bluetoothctl show` reports a powered BlueZ 5.62 adapter, `bluealsa` stays up,
and the ctl plugin attaches. With AirPods Pro paired and connected, `bluealsa`
registers the A2DP PCM and `amixer scontents` through the default ctl enumerates
the device's playback switch and volume — which is the control `libmsettings`'
`get_a2dp_simple_control_name()` looks for. **Audio plays** — the whole path from
an emulator through `bluealsa` to a paired headset works, subject to the WiFi
coexistence below.

Confirmed earlier on a stock device with Bluetooth switched on: `rtk_btusb` loaded,
`hci0` present with an `rfkill` entry, and `dbus-daemon --system`,
`bluetoothd -n` and `bluealsa -p a2dp-source` all running. Every library added
for Bluetooth appears in one of their `/proc/<pid>/maps` — `bluealsa` pulls the
widest set (gio, gobject, gmodule, mount, blkid, ffi, mpg123, sbc, bluetooth),
`bluetoothd` maps only dbus, glib, pcre and iconv. No `/var/lib/bluealsa` is
needed; BlueZ creates its adapter directory under the `/var/lib/bluetooth` link
on first power-on.

`rtk_btusb.ko` is 2.3 MB on disk but 72 KB once loaded: it ships `with
debug_info`, and `strip --strip-debug` takes it to 131 KB. `build-rootfs.sh`
does that: insmod reads the whole file, so it shortens Bluetooth power-on. Boot
is unaffected, since nothing loads it until Bluetooth is turned on.

`hciattach` is not harvested. `bt_init.sh` only reaches it if `hci0` never
appears, and the call it makes there (`hciattach -n ttyS1 xradio`) is for a
different Miyoo platform, so it cannot succeed on this hardware either way.

### Bluetooth audio quality is a radio problem, not a rootfs one

A2DP dropouts under emulation are **not** a missing BaseOS piece. `dmesg` shows
`rtk_btcoex: count_a2dp_packet_timeout` once a second with the count falling from
143 to ~102, each dip alongside an `RTW: Turbo EDCA` change: WiFi and Bluetooth
share one 2.4 GHz front-end and the driver time-slices it. minarch logs
`snd_pcm_recover` underruns to match. Merely being *associated* is enough —
measured 1.5 KB of wlan0 traffic over 10 s while the dips continued.

Stock cannot be doing anything smarter, and its boot was checked for it: no
`/etc/sysctl.conf`, no `/etc/modprobe.d`, empty `/etc/pm/{config,power,sleep}.d`,
and one udev rule for PulseAudio, which NextUI does not use. Same kernel, same
driver, same coexistence. The levers that do exist are NextUI's, and work on both:
turn WiFi off, or set CPU speed to `performance` — `governor.sh auto` leaves
`schedutil` free to fall to 600 MHz mid-frame while SBC encoding.

### Where this differs from BaseOS for H700

Same principles, different vendor tree; the entry points NextUI uses differ per
platform. Useful when reading [upstream](https://github.com/pvaibhav/BaseOS) for prior art.

| | H700 | my355 |
|---|---|---|
| curl | static, built in a container | harvested — OpenSSL 1.1 and zlib are already carried for `wpa_supplicant`, so it costs 640 KB |
| DHCP | BusyBox `udhcpc` + event script | same, behind the `S41dhcpcd` name |
| NTP entry point | NextUI calls `timedatectl set-ntp`, so BaseOS ships a `timedatectl` shim over a `baseos-ntp` supervisor, with the preference on `/data` | NextUI calls `/etc/init.d/S49ntp` directly, so the init script *is* the shim |
| clock at boot | `hwclock -u -s` in `rcS` | same, plus `S49ntp` |
| `/etc/localtime` | → `/run/localtime`, restored by `timedatectl apply` | → `/userdata/localtime`, stock's target |
| zoneinfo | whole tree | whole tree minus `right/` |
| OS version string | not implemented for this platform in NextUI | `/usr/miyoo/version`, generated from `VERSION` |
| service shims | `systemctl`, `timedatectl` | `/etc/init.d/S*` |

NextUI's NTP preference is not a second mechanism competing with ours: it is
stored in NextUI's config, which the OS cannot read, and acted on only when the
user toggles it (`config.h:425` — the value "will only apply after reboot, unless
you set it through `PLAT_setNetworkTimeSync`"). Both paths drive the same
`S49ntp` and the same `pidof ntpd`. As on stock, a boot always starts `ntpd`
regardless of the stored toggle.

## Status messages

This device has no console, so `fbsplash` — built from `src/fbsplash.c`, static,
freetype — is the only way to tell the owner anything.
It reads panel geometry from the framebuffer and rotation from
`/etc/baseos-release` (`BASEOS_PANEL_ROTATION_CCW=0`; the Flip's 640x480 panel is
upright). `baseos-splash` wraps it and only ever overlays a status pill.

**The boot logo.** When the bootloader handed none to the kernel (no
`logo,offset` in the display route: the mainline U-Boot path), `rcS` runs
`fbsplash 0` in the background as soon as `/run` is mounted, lights the
backlight, and mounts debugfs, where NextUI's `launch.sh` reads the
backlight's duty to keep it lit. The logo reaches the panel when the kernel
brings it up, at ~2.4 s ([U-Boot](uboot.md), *The boot logo*). On the vendor
path, the vendor U-Boot's logo stays untouched until the frontend draws its
first frame.

`frontend-session` shows `INSERT SD CARD` when the left slot is empty and
`ADD FRONTEND TO SD CARD` when a card is in it but carries no frontend — two cards
is the recommended setup, so an empty left slot asks for the card, not for a
frontend on this one, and logs each step to the one log above.

## Not yet done

- Root is mounted `rw`; a read-only root with writable state on `/data` is the
  target ([decisions](decisions.md)).
