# What frontends need from the rootfs

The interface a rootfs built from source has to keep, so that stock-built
frontends run unmodified, and how each piece of the harvest
(`manifest/harvest.list`) relates to it. Everything else in the harvest can be
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
| `libmali.so.1`, `libmali_hook.so.1`, `libEGL`, `libGLESv2`, `libgbm` | 16, 15, 4 | SDL2, GLideN64 | stock's names | built by `build-gpu.sh` |
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
| `miyoo_inputd` | `MinUI.pak/launch.sh` | already an `overlay/` shim |

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

Also named, all from `overlay/` or the build: `/etc/passwd`, `group`,
`shells`, `hosts`, `resolv.conf`, `localtime`, `nsswitch.conf`, `fstab`,
`machine-id`, `os-release`, `/etc/baseos-release` and `/usr/miyoo/version`.

## Tier 5 — no source

`rtl8733bu_fw` and `rtl8733bu_config`, the Bluetooth firmware of the WiFi/BT
chip. Mainline `btusb` loads them as `rtl_bt/rtl8723fu_*`, links in
`overlay/`; the WiFi firmware is compiled into the `8733bu` driver. With BL31
and OP-TEE in `uboot.img`, these two files are all the stock firmware a rootfs
built from source still needs.

`rtk_btusb.ko` is in the harvest but no longer used: `build-rootfs.sh` puts the
mainline `btusb` stand-in at that path.

## Not seen by this scan

A `dlopen` with a computed name, a command assembled at run time, and anything
only spruceOS runs: the scan read NextUI's card. A spruceOS card, scanned the
same way, adds its own list.
