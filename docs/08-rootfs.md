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

- NextUI ships its own SDL, tinyalsa and sqlite in `.system/my355/lib`, so **the
  vendor ALSA stack is not needed at all**.
- `miyoo_inputd` does not link `/usr/miyoo/lib`; those three vendor libraries
  (`libgamename`, `libshmvar`, `libtmenu`) are referenced by `LD_LIBRARY_PATH`
  but never loaded.

**Preparation verifies the closure.** Every `DT_NEEDED` of every harvested ELF
must resolve inside the harvest or the build fails — which is what turns an
allowlist into a proven closed set. The assembled rootfs is checked the same way:
41 dynamic ELF objects, 0 unresolved. Runtime-confirmed on hardware:
`wpa_supplicant v2.9` and `dbus-daemon 1.12.20` both execute.

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

- NextUI has not actually been launched from BaseOS — the card's `primary`
  partition is empty. That is the real test of the table above.
- Which vendor daemons the frontend needs for brightness, battery and Bluetooth
  is unmeasured. H700 needed three shims; the my355 surface looks smaller.
- Root is mounted `rw`. H700 targets a read-only root with writable state on
  `/data` ([h700/06](../h700/06-status-and-lessons.md)).

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md)
