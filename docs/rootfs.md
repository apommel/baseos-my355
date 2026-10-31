# The rootfs

How the BaseOS userland is assembled, and what it must reproduce so NextUI
behaves exactly as it does on stock.

## Sources

One Buildroot build (`./build.sh`, `configs/baseos_my355_defconfig`)
assembles it, with the kernel and U-Boot:

1. **Packages**: a merged `/usr` as the vendor rootfs has, with every library
   and program a frontend uses ([what frontends need](rootfs-interface.md)),
   and BaseOS's own tools from `src/` (`baseos-tools`).
2. **Static BusyBox** and its applet links — `rcS` calls `/bin/mount` and
   friends by path. Installed first, so a full program wins a name both have.
3. **`board/my355/rootfs-overlay/`** — `init`, `inittab`, `rcS`, `rcK`, the
   frontend session, the USB gadget — over the packages; with `--diag`,
   `board/my355/diag/rootfs-overlay/` too.
4. **`board/my355/post-build.sh`**: the assets, the version files, and the
   run path below. It fails the build if any program lacks a library it links.
5. **`board/my355/post-fakeroot.sh`**: the links into `/run` and `/data` a
   read-only root needs.

The two stock files left, the Bluetooth firmware, come from
`package/stock-firmware`.

## What it holds is measured, not guessed

Until 1.3.0 the userland was a harvest of the stock rootfs, its list read off
`/proc/<pid>/maps` across the running NextUI stack on hardware. Buildroot now
builds all of it but the Bluetooth firmware, from the interface
[what frontends need](rootfs-interface.md) measured from a card.

Two findings keep it small:

- NextUI ships its own tinyalsa and sqlite in `.system/my355/lib`, but uses
  the rootfs's SDL2 ([what frontends need](rootfs-interface.md)).
- `miyoo_inputd` does not link `/usr/miyoo/lib`; those three vendor libraries
  (`libgamename`, `libshmvar`, `libtmenu`) are referenced by `LD_LIBRARY_PATH`
  but never loaded.

**The build verifies the closure.** `post-build.sh` fails if any `DT_NEEDED`
of any ELF in the rootfs does not resolve inside it. What it cannot verify is
below.

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
| `fsck.fat` | `mount-frontend` | clears a card's FAT dirty flag before it is mounted (below). dosfstools 4.2, libc only |
| `mkfs.ext4` | spruceOS `setup_32bit_libs.sh` | formats the image behind spruceOS's `/usr` overlay. `/etc/mke2fs.conf`, stock's, is in `rootfs-overlay/` |
| `bash` | spruceOS | PortMaster ports, and root's shell in spruceOS's `/etc/passwd`. `/etc/shells` lists it, in `rootfs-overlay/` |
| `bluealsa-aplay` | spruceOS `bt_audio_ready()` | detects a Bluetooth headset |

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

While it retries, though, it hears no SIGTERM: musl's resolver waits out its
5 s timeout per lookup through the signal, and with no network the three peers
kept a stop pending for up to 11 s. So `S49ntp stop` uses SIGKILL, since `ntpd`
has nothing to save, and `rcK` calls it before signalling everything else. `start` ignores
an `ntpd` that has exited but is not yet reaped; init reaps orphans about once a
second, and `pidof` alone turned every `restart` into a stop.

### Version identity

`/etc/baseos-release` carries `BASEOS_TARGET` and the panel rotation `fbsplash`
reads; `post-build.sh` appends `BASEOS_VERSION` from `VERSION` and a
`git describe` `BASEOS_BUILD`. An uncommitted
tree's `-dirty` id gets a UTC timestamp appended, so two such builds never share
an id: a card skips a same-version payload whose id matches its own.
`post-image.sh` puts the same id in the `.bosupd` manifest.

`/usr/miyoo/version` is written from the same variable and reads
`BaseOS <version>`. It exists because `PLAT_getOsVersionInfo()` reads that path for the About screen
and passes the buffer to `getFile()`, which leaves it untouched when the file is
missing — so the caller's uninitialised 128-byte stack buffer is what Settings
renders, and what `settings.cpp` logs at start-up. That is the garbage in the
"Stock OS version" row, and the crash when the bytes contain no terminator.

## Boot path

```
kernel  --init=/init-->  /init  --exec-->  busybox init  --sysinit-->  /etc/init.d/rcS
                                                         --respawn-->  /usr/sbin/wifibtd, /sbin/frontend-session
```

`init=/init` is not optional; see [the card](card.md).

`rcS` runs in **0.06 s**, with `dbus-daemon --system` started in the background
(see [boot time](boot-time.md)). It stays short because the kernel does the
work an init script would otherwise do: `devtmpfs` is mounted by the kernel,
and the panel and storage are built in. The GPU driver is the one module it
loads (`baseos-gpu`, in the background); WiFi and Bluetooth load with their
radio ([mainline compatibility](mainline-compat.md)).

What it does do: tmpfs skeleton, `/data` (`mmcblk1p4`), machine-id,
**loopback**, zram swap in the background, the first-boot card expansion, the
frontend card, any pending system update, and the settings, SSH and the USB
gadget in the background. Of the two update hooks,
`baseos-update boot-check` after `/data` only runs when a trial is pending (a
builtin file test). `apply` after the card mount costs a failed glob
([the card](card.md)). This card's exFAT partition, where `baseos.conf` and
payloads may sit, is mounted read-only once for `baseos-gpu`, `apply` and the
settings, and unmounted in the background once the settings are read. Each
mount costs ~10 ms on FAT32 and ~20 on exFAT, which reads its allocation bitmap. `baseos.conf` is reached through `/run/baseos.conf`,
a symlink to wherever the volume is, rather than a copy that would put a cleartext
password on tmpfs.

`rcK` does the shutdown work busybox init leaves out. It stops every other
process (SIGTERM, at most 5 s, SIGKILL), unmounts the frontend's binds, the card
and `/data`, and puts `/` back to read-only in case it was remounted for
development. Without that, the `/data` journal replays on every boot.

The 5 s are for the frontend. A shutdown that does not come from NextUI
(`reboot` over adb, for one) finds `nextui.elf` still running, and SDL turns its
SIGTERM into `SDL_QUIT`, which NextUI handles as its own power-off: the
"Powering off" screen, a 2 s pause, then a clean exit. A 1 s limit killed it
halfway; given 5 s, it exits by itself in 2.7 s. A killed process also shows as a zombie while its other threads are
still letting go of its files: `nextui.elf` killed this way stayed `Z` with 2
threads for about 0.3 s, which is why the card stayed busy after nothing seemed
to hold it. So `rcK` waits for zombies too, until init reaps
them. An unmount that still fails is left read-only. A card left dirty anyway, by
a power cut or a hard power-off, is repaired at the next mount
([below](#nextui-compatibility)).

A frontend can also stack mounts on the card. spruceOS puts an overlay over
`/usr` whose upper layer is an ext4 image on the card, mounts squashfs images
from it, and can swap to a file on it. `rcK` would then run its own shell from
the card and keep it busy, so it first lazily detaches whatever is mounted over
`/usr` and runs itself again from the root filesystem's `/usr`. It turns swap
off before unmounting. Checked on the device with spruceOS running: `reboot` over
adb left the card clean, where a process running from such an overlay keeps the
card from unmounting. So a frontend needs no unmount of its own: calling
`poweroff` or `reboot` is enough, and init stops respawning `frontend-session`
once it has started `rcK`.

### The root is read-only

It is EROFS, lz4hc in 16 KiB clusters, so it cannot be written at all. Runtime state lives on
`/data`, on tmpfs (`/tmp`, `/run`, `/var`, `/dev/shm`) or on the frontend card
through the `/userdata` bind; `resolv.conf`, `machine-id` and `localtime` are
baked symlinks into those. Root's home, `/root`, links to `/data/root`, which
`/etc/init.d/dev` creates, so shell history and `.ssh/authorized_keys` persist.
`/etc/shadow`, `/etc/hostname` and `/etc/hosts` link into `/run`, where
`baseos-config` writes them at every boot from the card's `baseos.conf`
([below](#settings-come-from-the-card)). `passwd` fails; the password is set there.

To change a file on a running device, bind a copy over it until the next
boot: `cp /usr/sbin/x /data/x`, edit, `mount --bind /data/x /usr/sbin/x`.
Anything that tries to write to the root fails with `Read-only file system`,
which the log shows. `rcK` also leaves `/data/clean-shutdown`, which tells the next `rcS`
that this boot's crash record is not a crash ([diagnostics](diagnostics.md)).

### Swap is compressed RAM

`/dev/zram0`, half of RAM (~485 MB), at priority 100, so the kernel fills it
before any swap a pak adds: the N64 pak's file goes to `/mnt/UDISK`, which
exists only on stock, so without zram that pak runs with none. It holds RAM
only as pages arrive, so a frontend that fits in memory never touches it; on
the system's own binaries it stored 177 MB in 109 MB (LZO, 2026-10-30).
spruceOS runs its own `enable_zram.sh`, which keeps an active `zram0`, and
resets it when its "Use ZRAM" setting is off.

### The GPU library is read ahead

Every NextUI program links libmali, 58 MB, and the first to start faults in
~19 MB of it one page at a time: 0.53 s at boot, most of the frontend's
start. `baseos-gpu` reads the selected stack's library (libmali, or Mesa's
`libgallium`) with `cat` in the background, in the idle I/O class so the
rest of boot's reads go first. A list of the ranges a boot used, recorded
and replayed, did ~70 ms better, but followed whichever frontend and `gpu=`
had recorded it. Measurements are in [mainline compat](mainline-compat.md).

The root is EROFS because the same faults read half the bytes there. Larger
clusters, zstd or squashfs decode slower than ext4 reads.

### Settings come from the card

`baseos.conf`, at the root of this card's exFAT volume (`mmcblk1p5`), holds the
settings a user may change: `hostname` (default `miyoo-flip`) and `ssh_password`
(default `root`). The format and parser are upstream's; its `mdns` and
`headphone_pop_fix` keys are not carried. `/etc/init.d/dev` runs `baseos-config`
before it starts `dropbear`: it reads `/run/baseos.conf`, which `rcS` links to the
file where that volume is mounted. That is off the boot path,
since `dev` is in the background and nothing before SSH needs either setting. The
file is card data, parsed and never sourced; the cleartext password goes through
`mkpasswd -P 0` into `/run/shadow`, built from the baked copy in
`/usr/share/baseos/shadow`. `S41dhcpcd` sends the hostname with its DHCP requests,
so the router can name the lease. `expand-storage` puts a commented template on
the card on first boot, unless one is already there.

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
`fsck.fat`, `fsck.exfat`, `gunzip`, `gptslot`, `mkfs.exfat`, `unzip` — which is redirected straight at
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
(Upstream patches `adb.c` for the same result; this adbd needs only the
unset variable.) Debian's port, which Buildroot's `android-tools` is, fills
the connection banner with a Nexus 4's names; `patches/android-tools` makes
`adb devices -l` show the Flip.

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

**It stays running to rebind.** When the link errors out, as it can after a
resume, `adbd` closes and reopens functionfs, and the kernel unbinds the gadget
on that close. Nothing else binds it again, so the script checks `UDC` every
2 s and rewrites it once `ep1` is back (`UDC rebound` in the log). Builtins only:
the wait is a `read -t` on a FIFO nobody writes, so a check costs no fork,
measured at about 0.03% of one core.

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
normally goes in the **left** slot (`mmcblk2p1`); this card's own exFAT partition
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

**A dirty card is repaired before it is mounted.** Linux sets a FAT volume's
dirty flag at mount and clears it at a clean unmount, but never clears one it
found set. Only `fsck.fat` does, and macOS's Disk Utility does not, so a card
once powered off while mounted warned on every mount after, on any computer.
Before each mount, `fatdirty` (`src/fatdirty.c`) reads the boot sector, tells
FAT from exFAT, and tests the flag where the kernel reads it (offset 65 on
FAT32, 37 on FAT12/16, bit 1 of the VolumeFlags at 106 on exFAT); a set flag
runs dosfstools' `fsck.fat -a`, or exfatprogs' `fsck.exfat -a`, under `REPAIRING SD
CARD`. The type it prints also picks the mount, since the two take different
options: vfat `utf8`, and `iocharset=utf8` for exFAT, whose UTF-8 needs no NLS
table. Either card works in either slot. A clean card costs one exec, 1.8 ms
measured on the device; a volume that is neither is not mounted, and one in use
is left alone: `fatdirty` opens the device `O_EXCL`, which fails while
any filesystem holds it, including one lazily unmounted but still held. The repair took 5.0 s on a 115 GiB card
with 5,704 files in the left slot. The pill carries no progress track: fsck
reports none. Its output goes to the log, and a failed repair still mounts the
card as it is.

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
executed, but whether spruceOS finds the userland it expects in this rootfs
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
SDL2/`_image`/`_ttf` — in the rootfs — and embeds its font.

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
| `S36load_wifi_modules` | loads `8733bu` and seeds `/userdata/cfg/wpa_supplicant.conf`. Also WiFi's side of the WiFi/BT chip's power ([power](power.md)) | no — the frontend calls it when WiFi goes on or off |
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

Two details. `wifi_init.sh` starts DHCP *before* `wpa_supplicant`, so `wlan0`
has no carrier yet. `udhcpc -b` looked right and was not: it backgrounds only
after a whole round of DISCOVERs fails (3 × 5 s), then pauses 20 s, so turning
WiFi on blocked for 17.8 s and the address came at 37.5 s. `S41` now runs
`udhcpc -f` in the background itself and retries every second (`-T 1 -A 2`):
2.5 s and 9.4 s, of which association is 7.5 s.
And stock's `S41dhcpcd` wraps the daemon in `start-stop-daemon`; ours invokes
`udhcpc` directly.

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
| `rtk_btusb.ko` | the transport: `stock/0102`, a stand-in that loads `8733bu` and mainline `btusb` ([mainline compatibility](mainline-compat.md)). `btrtl` loads stock's `rtl8733bu_fw` and `rtl8733bu_config` through the `rtl_bt/rtl8723fu_*` links |
| `bluetoothd`, `bluetoothctl`, `bluealsa`, `hciconfig`, `hcitool` | plus `libbluetooth`, `libsbc` and the glib stack. `hcitool` is not optional: `PLAT_bluetoothConnected()` greps `hcitool con` for an `ACL` line, and its `popen` fallback only fires when `popen` itself fails — a missing binary just reads as "not connected", so the status-bar icon never appears |
| `S40bluetooth` | ours. Stock's wraps `bluetoothd` in `start-stop-daemon`. It keeps a `pidof dbus-daemon` guard so it still works if the bus is somehow down, though `rcS` starts it. **BlueZ 5 never forks**: run it in the foreground and the script blocks, `bt_init.sh` blocks behind it and Settings hangs on "Enabling Bluetooth…" — so `setsid … -n &`, which is what `start-stop-daemon -b` was doing |
| `/etc/bluetooth`, `/etc/dbus-1/system.d/*.conf` | installed by BlueZ and bluez-alsa |
| the `dbus` user | D-Bus's `system.conf` drops privileges to it, so `passwd`, `group` and `shadow` must all name it `dbus`; an Ubuntu-style `messagebus` makes `dbus-daemon --system` refuse to start |
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

BaseOS also cuts the WiFi/BT chip's power while both radios are off, which
`bt_init.sh` cannot see: `wifibtd` turns its `insmod` and its rfkill switching
into the Bluetooth half of that decision ([power](power.md)).

Exercised on BaseOS, on the vendor kernel and the harvest: `bt_init.sh` loads
`rtk_btusb` from `/lib/modules`, `hci0` comes up with the same BD address as stock (so the
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

On mainline the stand-in is a few KB, where stock's module was 2.3 MB read on
every Bluetooth power-on; `hci0`, `btrtl`'s firmware load and both radios were
checked on this build (2026-10-31).

`hciattach` is not installed. `bt_init.sh` only reaches it if `hci0` never
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
| curl | static, built in a container | Buildroot's, over the OpenSSL 3 `wpa_supplicant` uses too |
| DHCP | BusyBox `udhcpc` + event script | same, behind the `S41dhcpcd` name |
| NTP entry point | NextUI calls `timedatectl set-ntp`, so BaseOS ships a `timedatectl` shim over a `baseos-ntp` supervisor, with the preference on `/data` | NextUI calls `/etc/init.d/S49ntp` directly, so the init script *is* the shim |
| clock at boot | `hwclock -u -s` in `rcS` | the kernel, from the RTC, plus `S49ntp` |
| `/etc/localtime` | → `/run/localtime`, restored by `timedatectl apply` | → `/userdata/localtime`, stock's target |
| zoneinfo | whole tree | whole tree minus `right/` |
| OS version string | not implemented for this platform in NextUI | `/usr/miyoo/version`, generated from `VERSION` |
| service shims | `systemctl`, `timedatectl` | `/etc/init.d/S*` |
| `baseos.conf` | applied by `rcS` before any service, sharing the update's mount of TF1; `hostname`, `mdns`, `ssh_password`, `headphone_pop_fix` | applied by the backgrounded `dev`; `hostname` and `ssh_password`, and the hostname also goes to DHCP |

NextUI's NTP preference is not a second mechanism competing with ours: it is
stored in NextUI's config, which the OS cannot read, and acted on only when the
user toggles it (`config.h:425` — the value "will only apply after reboot, unless
you set it through `PLAT_setNetworkTimeSync`"). Both paths drive the same
`S49ntp` and the same `pidof ntpd`. As on stock, a boot always starts `ntpd`
regardless of the stored toggle.

## Status messages

This device has no console, so `fbsplash` — built from `src/fbsplash.c` with
freetype — is the only way to tell the owner anything.
It reads panel geometry from the framebuffer and rotation from
`/etc/baseos-release` (`BASEOS_PANEL_ROTATION_CCW=0`; the Flip's 640x480 panel is
upright). `baseos-splash` wraps it and only ever overlays a status pill.

**The boot logo.** When the bootloader handed none to the kernel (no
`logo,offset` in the display route: the mainline U-Boot path), `rcS` runs
`fbsplash 0` in the background as soon as `/run` is mounted and lights the
backlight. The logo reaches the panel when the kernel brings it up, at 1.61 s
([U-Boot](uboot.md), *The boot logo*), and stays untouched until the frontend
draws its first frame.

`frontend-session` shows `INSERT SD CARD` when the left slot is empty and
`ADD FRONTEND TO SD CARD` when a card is in it but carries no frontend — two cards
is the recommended setup, so an empty left slot asks for the card, not for a
frontend on this one, and logs each step to the one log above.
`mount-frontend` shows `REPAIRING SD CARD` while fsck runs on a card that
was not cleanly unmounted; the frontend's first frame replaces it.

In both states nothing reads the power key, and holding it is the PMIC's hard
power-off. So `frontend-session` also starts `pwrkeyd` (`src/pwrkeyd.c`), once,
which runs `poweroff` once the key has been held for 2 s, longer than the
500 ms that boots, so that turning off stays deliberate; a shorter press does
nothing. `rcK` then stops everything and unmounts as on any shutdown. `pwrkeyd` opens `rk805 pwrkey` by
name, since the lid's hall sensor reports `KEY_POWER` too, and is stopped before
the frontend starts, as NextUI reads the key itself.
