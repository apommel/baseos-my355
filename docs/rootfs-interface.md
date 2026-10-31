# What frontends need from the rootfs

The interface a rootfs built from source has to keep, so that stock-built
frontends run unmodified, and how each piece of the stock harvest relates
to it. Everything else in the harvest can be
replaced by a current build.

## How it was measured

`tools/frontend-abi.sh` pulls over adb every ELF and script in the card's
`.system/my355`, `.tmp_update`, `Emus/my355` and `Tools/my355`, and the maps of
every running process, into `work/abi/`. `tools/abi_scan.py` then reports, per
rootfs library, which programs link it, which symbols they import and which
symbol versions those need; library names they carry without linking
(`dlopen`); rootfs programs named as a command; and rootfs paths named.
`--no-pull` rescans what is already there.

Binaries under another platform's directory (`tg5040/`, `h700/`, …) are left
out: paks ship them side by side and pick one by `$PLATFORM`. A library is
counted as the card's own when it sits in the program's pak or in
`.system/my355/lib`.

The first run, 2026-10-30: NextUI `20261028-my355` (`ffee1f21`), its 33 emulator
paks and 16 tools, NextUI idle in its menu. 95 ELFs, 72 scripts. The
JSON report lists every symbol.

## What it found

- **Nothing on the card needs newer than glibc 2.36, `GLIBCXX_3.4.22` or
  `CXXABI_1.3.9`** (GCC 6). Any current toolchain is newer, and newer is
  what works.
- **NextUI does not ship its own SDL.** `.system/my355/lib` has sqlite,
  tinyalsa, zip and compression libraries; SDL2 and its two add-ons are the
  rootfs's, linked by 36 programs. [rootfs](rootfs.md) said otherwise.
- **Every library a frontend links is one with a stable ABI**: glibc, the
  GCC runtime, SDL2, libdrm, zlib, alsa-lib, libdbus, libudev and the GPU
  stack. None is a vendor fork except the GPU stack, which BaseOS already
  builds ([mainline compatibility](mainline-compat.md)).
- **The rest of the harvest is programs frontends run by name, and the
  libraries those programs need.** For them, only the command line and
  behaviour matter.

## Tier 1 — libraries linked into frontend processes

Their sonames and symbol versions are the ABI. Any newer release of the same
soname keeps it; each needs a behaviour check on the device, not only a link
check.

| library | linked by | dlopened by | what it carries | stock |
|---|---|---|---|---|
| glibc: `libc`, `libm`, `libdl`, `libpthread`, `librt`, `libresolv`, `ld-linux` | 91 | — | up to `GLIBC_2.36` | already Debian 2.41 |
| `libnss_files`, `libnss_dns` | — | glibc (NSS), `7zzs` | `/etc/nsswitch.conf` | already Debian |
| `libstdc++`, `libgcc_s`, `libatomic` | 26, 26, 1 | — | `GLIBCXX_3.4.22`, `CXXABI_1.3.9`, `GCC_4.5.0` | already Debian GCC 14 |
| `libSDL2-2.0.so.0` | 36 | — | 536 symbols | 2.0.18–2.0.22 |
| `libSDL2_image-2.0.so.0`, `libSDL2_ttf-2.0.so.0` | 26, 28 | — | 40 and 36 symbols | harvested |
| `libdrm.so.2` | 17 | SDL2 | 25 symbols | harvested |
| `libz.so.1` | 21 | — | `ZLIB_1.2.2` | 1.2.11 |
| `libasound.so.2` | Dolphin | SDL2, `nextui.elf`, `minarch.elf`, 6 tools | 21 symbols, `ALSA_0.9`; reads `/usr/share/alsa` | harvested |
| `libasound_module_{pcm,ctl}_bluealsa.so` | — | alsa-lib, from the `.asoundrc` `audiomon` writes | alsa-lib's plugin ABI; talks to `bluealsa` over D-Bus | bluez-alsa 4.0.0 |
| `libdbus-1.so.3` | `audiomon.elf` | SDL2 | 19 symbols, `LIBDBUS_1_3` | dbus 1.12.20 |
| `libudev.so.1` | `audiomon.elf`, Dolphin | SDL2 | 28 symbols, `LIBUDEV_183` | harvested, 137 KB |
| `libmali.so.1`, `libmali_hook.so.1`, `libEGL`, `libGLESv2`, `libgbm` | 16, 15, 4 | SDL2, GLideN64 | stock's names | `libmali`, or `mesa-panfrost`'s stand-ins |
| `libvulkan.so.1` | — | SDL2 | the loader | already Debian |

Behind SDL2's two add-ons, and nowhere else on the card: `libfreetype.so.6`,
`libpng16.so.16` (1.6.37) and `libiconv.so.2`. They are free to change with the
add-ons: no card program links them. `libiconv` is GNU libiconv, linked by
stock's SDL2; one built against glibc's iconv drops it.

Behaviour stock's SDL2 is known to be relied on for, to check after an
upgrade: joystick button indices ([mainline compatibility](mainline-compat.md)),
its handling of an HDMI connector with no mode (2026-10-30 in
[history](history.md)), KMSDRM frame pacing on both GPU stacks, and ALSA
latency in `minarch`.

## Tier 2 — programs frontends run

Called by name from NextUI's binaries, `libmsettings.so` and scripts. Their
command line and output are the interface; their libraries are private to
them.

| program | run by | stock |
|---|---|---|
| `amixer` | `libmsettings.so`, `suspend` | alsa-utils |
| `modetest` | `libmsettings.so` | libdrm (static) |
| `curl` | `minarch.elf`, Base Jumper, RA Explorer, … | 7.79.1, OpenSSL 1.1.1l |
| `wpa_supplicant`, `wpa_cli` | `nextui.elf`, `minarch.elf`, `suspend`, `wifi_init.sh` | 2.9 |
| `bluetoothctl`, `hciconfig`, `hcitool`, `bluetoothd` | `nextui.elf`, `minarch.elf`, `bt_init.sh` | BlueZ 5.62 |
| `bluealsa` | `audiomon.elf`, `minarch.elf`, `bt_init.sh` | bluez-alsa 4.0.0 |
| `bluealsa-aplay`, `bash`, `mkfs.ext4` | spruceOS ([rootfs](rootfs.md)) | |
| `miyoo_inputd` | `MinUI.pak/launch.sh` | already a `rootfs-overlay/` shim |

Also named, all BaseOS's own already: `/etc/init.d/S36load_wifi_modules`,
`S40bluetooth`, `S41dhcpcd`, `S49ntp`, `dev`, and `/usr/sbin/poweroff`.

Their private libraries, which go with them: OpenSSL 1.1 (`libssl`,
`libcrypto`), `libcurl`, `libnl-3` and `libnl-genl-3`, GLib (`glib`, `gio`,
`gobject`, `gmodule`) with `libffi.so.8`, `libpcre.so.1`, `libmount` and
`libblkid`, `libbluetooth`, `libsbc`, `libmpg123`, `ncurses`, `readline` and
`history`, and e2fsprogs' `libext2fs`, `libcom_err`, `libe2p` and `libuuid`.
No card program links any of them.

## Tier 3 — programs only the OS runs

`adbd` (Android's 4.2-era `core/adbd`), `dropbear` and `gesftpserver`,
`dbus-daemon` (with `libexpat`), `fsck.fat` (by `mount-frontend`). No
frontend touches them, so any current version will do.

## Tier 4 — data read in place

| path | read by |
|---|---|
| `/usr/share/zoneinfo`, `zone.tab` | `nextui.elf`, `minarch.elf`, Settings |
| `/etc/ssl/certs`, `ca-certificates.crt`, `/usr/share/ca-certificates` | curl, Dolphin, RA Explorer, ScrapeGoat's git |
| `/usr/share/alsa` | alsa-lib |
| `/etc/dbus-1`, `/usr/share/dbus-1`, `/etc/bluetooth` | dbus-daemon, BlueZ |

Also named, all from `rootfs-overlay/` or the build: `/etc/passwd`, `group`,
`shells`, `hosts`, `resolv.conf`, `localtime`, `nsswitch.conf`, `fstab`,
`machine-id`, `os-release`, `/etc/baseos-release` and `/usr/miyoo/version`.

## Tier 5 — no source

`rtl8733bu_fw` and `rtl8733bu_config`, the Bluetooth firmware of the WiFi/BT
chip. Mainline `btusb` loads them as `rtl_bt/rtl8723fu_*`, links in
`rootfs-overlay/`; the WiFi firmware is compiled into the `8733bu` driver. With BL31
and OP-TEE in `uboot.img`, these two files are all the stock firmware a rootfs
built from source still needs.

`rtk_btusb.ko` is in the harvest but no longer used: the build puts the
mainline `btusb` stand-in at that path.

## How the rootfs provides it

Buildroot builds everything above but the firmware (`configs/` and BaseOS's
own packages in `package/`). One toolchain and
one glibc for all of it, current releases, and each package configured for
this device: no systemd, X11, Wayland or PulseAudio. Buildroot 2026.08.1:

| | stock | now |
|---|---|---|
| glibc, GCC runtime | 2.36, GCC 11 | 2.44, GCC 15.3 |
| SDL2 | 2.0.18–2.0.22 | sdl2-compat 2.32.74 over SDL3 3.4.12 |
| SDL2_image, SDL2_ttf | harvested | 2.8.12, 2.24.0 |
| alsa-lib, alsa-utils | harvested | 1.2.16 |
| libdrm | harvested | 2.4.134 |
| libudev | 137 KB, `LIBUDEV_183` | libudev-zero 1.0.5, `LIBUDEV_183` |
| D-Bus | 1.12.20 | 1.16.2 |
| BlueZ, bluez-alsa | 5.62, 4.0.0 | 5.86, 4.3.1 |
| wpa_supplicant | 2.9 | 2.12 |
| curl, OpenSSL | 7.79.1, 1.1.1l | 8.22.0, 3.6.5 |
| libmali | g13p0 | g29p1, a Buildroot package |
| adbd | Android 4.2 `core/adbd`, as a Nexus 4 | the same, `android-tools`, as the Miyoo Flip |
| dropbear | harvested | 2026.94 |
| CA certificates | harvested | Mozilla's, 2026-08-16 |
| tzdata | harvested | 2026e |

Three choices behind it:

- **sdl2-compat over SDL3**, not SDL2: SDL2 is in maintenance, and
  sdl2-compat is how SDL2 programs run on SDL3. It implements the whole SDL2
  ABI, including `SDL_GetWindowWMInfo` on KMS/DRM, and loads `libSDL3.so.0` at
  run time. Buildroot's `sdl3` package turns off HIDAPI, D-Bus and Vulkan, all
  of which stock's SDL2 had, so BaseOS builds its own (`baseos-sdl3`), and its
  own SDL2_image and SDL2_ttf, since Buildroot's need its `sdl2`.
- **libudev-zero**, not eudev: stock ran no udev daemon either, and
  libudev-zero reads kernel events directly. A patch applies its symbol map,
  which its Makefile leaves out, so imports at `LIBUDEV_183` resolve.
- **libmali as the GL provider**, so SDL3's KMS/DRM backend builds against
  it. Mesa (`mesa-panfrost`) installs beside it in `/usr/lib/mesa`, with
  shaders precompiled by `host-mesa3d`, so the target needs no LLVM.

NextUI's `LD_LIBRARY_PATH` puts `.system/my355/lib` first for everything it
starts, rootfs programs included. That directory has its own OpenSSL 3
`libcrypto.so.3`, older than Buildroot's 3.6, which `libssl` needs, so
`wpa_supplicant` and `wpa_cli` failed to load and WiFi never came up. Stock's
OpenSSL 1.1 used other names. `post-build.sh` gives every Buildroot ELF a
`DT_RPATH` of `/usr/lib`, which glibc searches before `LD_LIBRARY_PATH` (a
`DT_RUNPATH` comes after it). Mesa's bind mounts over `/usr/lib` still apply.

`tools/abi_scan.py CARD rootfs.tar --baseline stock-harvest.tar` fails if any
import of a card program that resolves on stock does not resolve on the build,
symbol by symbol and at the version it needs. It also fails if a library in
`.system/my355/lib` would shadow a rootfs one without defining what rootfs
libraries import from it. Behaviour is the device's to show: SDL2's checks are
listed under tier 1.

### CA certificates

Shipped, and from Mozilla's current list rather than stock's 2021 copy:
`curl` (NextUI's HTTP), Dolphin, RA Explorer and ScrapeGoat's git read
`/etc/ssl/certs/ca-certificates.crt`, and Go programs (Grout, Pak Store) scan
`/etc/ssl/certs`. A bundle that ages out breaks HTTPS for all of them, so it
moves with each Buildroot update.

## Not seen by this scan

A `dlopen` with a computed name, a command assembled at run time, and anything
only spruceOS runs: the scan read NextUI's card. A spruceOS card, scanned the
same way, adds its own list.
