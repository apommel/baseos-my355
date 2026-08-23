# my355 · The rootfs

How the BaseOS userland for the Flip is assembled, and what it must reproduce so
NextUI behaves exactly as it does on stock.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Pipeline

```
./prepare-stock.sh   NAND backup → work/my355/prepared/
                             uboot.img, boot.img, stock-harvest.tar, source.json
./build-rootfs.sh    harvest + overlay + static BusyBox → rootfs.tar
./build-image.sh     prepared + rootfs → baseos-my355.img
```

This is the same shape as the H700 path, so the prepared set can later ship as a
release bundle the way `fetch-prepared.sh` restores one.

## Sources

Four, applied in order so each can override the last:

1. **Static BusyBox** (Alpine `busybox-static`), 305 applets, plus its applet
   symlinks — `rcS` calls `/bin/mount` and friends by path.
2. **The stock harvest** — 43 allowlisted paths from `mtd3`, 48 files, 31 MiB.
3. **The merged-`/usr` skeleton** the harvest assumes: `bin`, `sbin`, `lib`,
   `lib64` are symlinks and real content lives under `/usr`, exactly as the
   vendor rootfs is laid out.
4. **`overlay/`** — `init`, `inittab`, `rcS`, `rcK`, the frontend session,
   the USB gadget.

`mtd3` is **squashfs**, so preparation uses `unsquashfs`, not the H700 `debugfs`
path. It is unpacked to a container-local scratch directory, never a bind mount:
the stock rootfs contains both `/mnt/sdcard` and `/mnt/SDCARD`, which collide on
a case-insensitive host filesystem such as macOS.

## The harvest is measured, not guessed

`manifest/harvest.list` was derived by reading `/proc/<pid>/maps` across the
whole running NextUI stack on hardware — every entry was observed mapped, or is
needed by something that was.

Two findings make it much smaller than the H700 equivalent:

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
into and `nextui-session` bind-mounts onto the frontend card.

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

`/etc/baseos-release` is generated at build time from `VERSION`, as on H700, and
carries `BASEOS_VERSION` plus a `git describe` `BASEOS_BUILD`.

`/usr/miyoo/version` is written from the same variable and reads `BaseOS 1.1.0`.
It exists because `PLAT_getOsVersionInfo()` reads that path for the About screen
and passes the buffer to `getFile()`, which leaves it untouched when the file is
missing — so the caller's uninitialised 128-byte stack buffer is what Settings
renders, and what `settings.cpp` logs at start-up. That is the garbage in the
"Stock OS version" row, and the crash when the bytes contain no terminator.

## Boot path

```
kernel  --init=/init-->  /init  --exec-->  busybox init  --sysinit-->  /etc/init.d/rcS
                                                         --respawn-->  /sbin/nextui-session
```

`init=/init` is not optional; see [06](06-card-image-build.md).

`rcS` is short — measured at **60 ms** (`rcS-start 1.43`, `rcS-done 1.49`) — and
shorter than the H700 equivalent because this kernel does more for us:

| H700 does | my355 does not need to |
|---|---|
| mounts `devtmpfs` itself | `CONFIG_DEVTMPFS_MOUNT=y` |
| `insmod mali_kbase.ko` (~0.7 s, backgrounded) | Mali is built in |
| mounts `debugfs` for sunxi `dispdbg` | plain DRM, no such dependency |

What it does do: tmpfs skeleton, `/data` (`mmcblk1p4`), machine-id, entropy seed,
**loopback**, the frontend card, and the USB gadget in the background.

### Loopback is load-bearing

`adbd` binds a TCP listener during start-up and treats failure as fatal — it never
reaches `usb_ffs_init`, so no endpoints appear and the UDC bind silently does
nothing. Without `lo` there is no adb. Stock has `lo` up; nothing else in BaseOS
needs it.

## adb over USB

`usr/sbin/usb-gadget-adb` reproduces the configfs gadget stock builds with its
700-line vendor `usbdevice` script, reduced to what adb needs. The shape was read
off a running stock unit, not derived from the script:

```
gadget    rockchip      idVendor 0x2207  idProduct 0x0006  bcdDevice 0x0310
function  ffs.adb       functionfs at /dev/usb-ffs/adb, -o uid=2000,gid=2000
config    b.1 "adb"
UDC       fcc00000.dwc3
env       ADB_TCP_PORT=5555   (5037 is the host-server port — the wrong one)
```

**Ordering is load-bearing**: `adbd` must be running and have written its
descriptors before the UDC is bound, or the host sees a gadget with no endpoints.
A successful run logs:

```
1.57 start          1.60 gadget created      1.62 functionfs mounted: ep0
1.62 adbd started   1.84 after wait: ep0 ep1 ep2
1.85 UDC bound -> fcc00000.dwc3
```

It never blocks boot: no `set -e`, every failure path returns quietly, and `rcS`
backgrounds it. Because it must fail quietly, it **logs** to `/data/usb-gadget.log`
— persistent, and the only way to diagnose it on a device with no console.

> **Unlike H700, a cable is not required before power-on — verified.** That
> port's restriction comes from the sunxi OTG role manager, which clears the UDC
> binding on disconnect and wedges the kernel if its role attributes are touched
> ([h700/08](../upstream-h700/docs/08-usb-adb-and-otg.md)). RK3566 uses dwc3 with plain
> configfs and VBUS detection, and we only ever write `UDC`. Hot-plugging after
> boot works, which is also how a clean boot time gets measured.

## NextUI compatibility

The contract: starting NextUI from BaseOS must behave exactly as from stock,
differing only in which slot the card is in. NextUI itself is slot-agnostic —
nothing in `my355.sh` or `MinUI.pak/launch.sh` names a block device — so the whole
burden is in reproducing what stock's `runmiyoo.sh` sets up.

`rcS` mounts the frontend card at `/mnt/SDCARD`: the **left-slot** card
(`mmcblk2p1`) if present, else this card's own FAT partition (`mmcblk1p5`), and
symlinks `/mnt/sdcard` for the lowercase path stock uses. BaseOS takes the right
slot because it is the only slot the SPL can boot from.

`nextui-session` then reproduces, in order:

| | why |
|---|---|
| `$SDCARD/.userdata/my355/userdata` skeleton | stock creates it on first run |
| `system.json`, **byte-identical to the vendor heredoc** | decides volume, brightness, keymap on first launch |
| `mount --bind` it onto `/userdata` | where `wpa_supplicant.conf`, `system.json` and BT pairings live; stock does this because the internal userdata partition corrupts |
| `mount --bind /run/bluetooth_fix` over `/userdata/bluetooth` | BlueZ names pairing files by MAC, which FAT32 rejects |
| `exec .tmp_update/updater` | **not** `launch.sh` — the updater installs `MinUI.zip`/`*.pakz`, so updates behave the same |

Verified on hardware: both bind mounts appear in `/proc/mounts` on a booted
BaseOS system, and the session idles correctly when no frontend is present.

### Init-script contracts

NextUI's my355 build names four init scripts — from `etc/wifi/wifi_init.sh`,
`etc/bluetooth/bt_init.sh` and `platform.c`. They live on the frontend card, so
BaseOS has to answer to the names; the contents are ours. Stock's `rcS` runs
`for i in /etc/init.d/S??*`, so on stock all four also start at boot.

| script | BaseOS | at boot? |
|---|---|---|
| `S36load_wifi_modules` | nothing — the RTL8189FU driver is built into this kernel (`lsmod` is empty, yet `wlan0` exists and `RTW_CMD_THREAD` runs) | no |
| `S41dhcpcd` | BusyBox `udhcpc`, not the vendor `dhcpcd` | no — the frontend calls it when WiFi goes on |
| `S49ntp` | BusyBox `ntpd`, not stock's 757 KB one | yes — TLS depends on the clock |
| `S40bluetooth` | `bluetoothd`, after bringing the system bus up | no — the frontend calls it when Bluetooth goes on |

Only `S49ntp` runs at boot, and backgrounded. The others stay frontend-driven
because `wifi_init.sh` and `bt_init.sh` call them anyway and boot must not grow.

**DHCP.** Stock's `dhcpcd` 9.4.1 would mean a 368 KB binary, its hook and share
directories and a privsep user. BusyBox `udhcpc` is already in the image and needs
only an event script, so my355 follows H700
([h700/05](../upstream-h700/docs/05-runtime-power-network.md)):
`usr/share/udhcpc/default.script` sets the address, default route and
`/run/resolv.conf`, with `/etc/resolv.conf` a baked symlink to it.

Two details. `wifi_init.sh` starts DHCP *before* `wpa_supplicant`, so `udhcpc`
runs with `-b` rather than blocking the WiFi toggle while `wlan0` has no carrier.
And stock's `S41dhcpcd` wraps the daemon in `start-stop-daemon`, which Alpine's
`busybox-static` does not build — absent from the 305 applets here, so the script
invokes `udhcpc` directly.

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
| the `dbus` user | the harvested `system.conf` drops privileges to it. The overlay carried H700's Ubuntu name, `messagebus`, which would have made `dbus-daemon --system` refuse to start |
| `libasound_module_{pcm,ctl}_bluealsa.so` | the rest of `alsa-lib/` is unreferenced — nothing sets `defaults.pcm.rate_converter`, so `type plug` uses the built-in linear one |

`rcS` starts the system bus, as stock's `S30dbus` does. This is not for BlueZ's
benefit — NextUI's `audiomon.elf` connects to it at frontend start whether or not
Bluetooth is ever used, and **exits** if it cannot, which leaves nothing to write
`.asoundrc` and so no route to bluealsa. `system.conf` has `<fork/>`, so the call
returns once the socket is listening and there is no race with the frontend.
H700 starts dbus lazily instead, which is fine there: its NextUI build does not
ship `audiomon` at all.

`rcS` also adds two links: `/var/lib/dbus/machine-id` → `/run`, and
`/var/lib/bluetooth` → `/userdata/bluetooth`, which is stock's arrangement.
`nextui-session` already shadows that directory with a tmpfs because FAT32
rejects BlueZ's MAC-named files — so as on stock, pairings do not survive a
reboot.

Exercised on BaseOS: `bt_init.sh` loads `rtk_btusb` from the harvested
`/lib/modules`, `hci0` comes up with the same BD address as stock (so the
firmware harvest is right), `S40bluetooth start` returns in 0.05 s,
`bluetoothctl show` reports a powered BlueZ 5.62 adapter, `bluealsa` stays up,
and the ctl plugin attaches. With AirPods Pro paired and connected, `bluealsa` registers the A2DP PCM and `amixer scontents` through the default ctl enumerates the device's playback switch and volume — which is the control `libmsettings`' `get_a2dp_simple_control_name()` looks for. A2DP audio has not been listened to.

Confirmed earlier on a stock device with Bluetooth switched on: `rtk_btusb` loaded,
`hci0` present with an `rfkill` entry, and `dbus-daemon --system`,
`bluetoothd -n` and `bluealsa -p a2dp-source` all running. Every library added
for Bluetooth appears in one of their `/proc/<pid>/maps` — `bluealsa` pulls the
widest set (gio, gobject, gmodule, mount, blkid, ffi, mpg123, sbc, bluetooth),
`bluetoothd` maps only dbus, glib, pcre and iconv. Unlike H700 no
`/var/lib/bluealsa` is needed; BlueZ creates its adapter directory under the
`/var/lib/bluetooth` link on first power-on.

`rtk_btusb.ko` is 2.3 MB on disk but 72 KB once loaded: it ships `with
debug_info`, and `strip --strip-debug` takes it to 131 KB. Not done — the
harvest is verbatim, and the saving is not worth confusing the first hardware
test of the rest of this.

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

### Where my355 diverges from H700

Same principles, different vendor tree; the entry points NextUI uses differ per
platform.

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

This device has no console, so `fbsplash` — built from the shared
`src/fbsplash.c`, static, freetype — is the only way to tell the owner anything.
It reads panel geometry from the framebuffer and rotation from
`/etc/baseos-release` (`BASEOS_PANEL_ROTATION_CCW=0`; the Flip's 640x480 panel is
upright). `usr/bin/baseos-splash` wraps it, and ordinary boots never call it:
the bootloader logo stays untouched until the frontend draws its first frame.

`nextui-session` shows `INSERT SD CARD` and `ADD FRONTEND TO SD CARD`, and logs
to `/tmp/nextui-session.log`, mirrored to `baseos-session.log` on the card.

## Not yet done

- A2DP audio has not been heard from BaseOS. Pairing, connection and the mixer
  controls check out; nobody has played a sound through them.
- Root is mounted `rw`. H700 targets a read-only root with writable state on
  `/data` ([h700/06](../upstream-h700/docs/06-status-and-lessons.md)).

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
