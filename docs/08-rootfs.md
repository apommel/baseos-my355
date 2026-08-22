# my355 · The rootfs

How the BaseOS userland for the Flip is assembled, and what it must reproduce so
NextUI behaves exactly as it does on stock.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## Pipeline

```
./prepare-stock-my355.sh   NAND backup → work/my355/prepared/
                             uboot.img, boot.img, stock-harvest.tar, source.json
./build-rootfs-my355.sh    harvest + overlay-my355 + static BusyBox → rootfs.tar
./build-image-my355.sh     prepared + rootfs → baseos-my355.img
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
4. **`overlay-my355/`** — `init`, `inittab`, `rcS`, `rcK`, the frontend session,
   the USB gadget.

`mtd3` is **squashfs**, so preparation uses `unsquashfs`, not the H700 `debugfs`
path. It is unpacked to a container-local scratch directory, never a bind mount:
the stock rootfs contains both `/mnt/sdcard` and `/mnt/SDCARD`, which collide on
a case-insensitive host filesystem such as macOS.

## The harvest is measured, not guessed

`manifest/harvest-my355.list` was derived by reading `/proc/<pid>/maps` across the
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
> ([h700/08](../h700/08-usb-adb-and-otg.md)). RK3566 uses dwc3 with plain
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
| `S40bluetooth` | **not provided** — needs BlueZ | — |

Only `S49ntp` runs at boot, and backgrounded. The WiFi pair stays frontend-driven
because `wifi_init.sh` calls it anyway and boot must not grow.

**DHCP.** Stock's `dhcpcd` 9.4.1 would mean a 368 KB binary, its hook and share
directories and a privsep user. BusyBox `udhcpc` is already in the image and needs
only an event script, so my355 follows H700
([h700/05](../h700/05-runtime-power-network.md)):
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

- Bluetooth: BlueZ, `/etc/init.d/S40bluetooth` and the `alsa-lib` plugin
  directory are all absent, so pairing and the A2DP sink cannot work yet.
- Which vendor daemons the frontend needs for brightness, battery and Bluetooth
  is unmeasured. H700 needed three shims; the my355 surface looks smaller.
- Root is mounted `rw`. H700 targets a read-only root with writable state on
  `/data` ([h700/06](../h700/06-status-and-lessons.md)).

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [our own U-Boot](09-uboot.md)
