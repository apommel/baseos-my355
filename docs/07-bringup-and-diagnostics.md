# my355 · Bring-up and diagnostics

How to debug a boot on a device that cannot tell you anything.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

## The problem

This unit has **no UART attached** (the pads need the case open) and the vendor
kernel has **`# CONFIG_FRAMEBUFFER_CONSOLE is not set`**, so `console=tty0`
renders nothing. A successful boot and a dead one look identical: the U-Boot
logo, then stillness.

Getting this wrong wastes hardware round-trips. Four separate bring-up failures
below were each invisible, and two tests were designed that could not have
distinguished success from failure.

## Signals that do work

Ordered by how early they fire.

| signal | proves | how |
|---|---|---|
| **boot logo** | U-Boot ran *and* read the card's `boot` partition | `mkbootlogo_my355.py` repaints the vendor BMP; only our card carries it |
| **LED, kernel-side** | the kernel started and reached driver probe | DTB `/leds/work linux,default-trigger = heartbeat`; fires long before root is mounted |
| **reboot loop** | the kernel panicked (rather than hung) | `panic=10` on the command line |
| **LED, userspace** | init is alive *now* | init sets trigger `none` and drives `brightness` in a loop — stops the instant PID 1 dies |
| **files on the card** | how far init got | `rcS` appends to `/data/boot.log`, `usb-gadget-adb` to `/data/usb-gadget.log` — both persistent, both survive a power cut |

Both LED signals are distinguishable by eye: the kernel's `heartbeat` is a
double-thump; a userspace 1 s on / 1 s off loop is an even square wave.

Enable the first three with `MY355_DIAG=1 ./build-image-my355.sh`.

## Reading the card afterwards

The decisive trick. Put the BaseOS card in the **left slot**: it is not in
the SPL boot order, so the device boots **stock** from NAND instead,
and stock's kernel auto-mounts the card's ext4 partitions under `/media/`.
Everything the failed boot wrote is then readable over adb.

```sh
adb shell "grep mmcblk2 /proc/mounts"                    # find the mounts
adb shell "cat /media/sdcardN/BOOT-STAGE"                # how far init got
adb shell "dumpe2fs -h /dev/mmcblk2p3 | grep -E 'Last mounted on|Mount count'"
```

`Last mounted on: /` is conclusive proof the kernel mounted that partition as
root — which is how the final bug was found after the LED had already shown the
kernel was alive.

Stock also lets you test binaries against the *exact* kernel before trusting
them: `adb shell /media/sdcardN/bin/busybox` confirmed our static aarch64
busybox runs, ruling out the rootfs while the real bug was elsewhere.

## Failure signatures

| symptom | means |
|---|---|
| **backlight never lights** | U-Boot never reached display init. Prime suspect: the resource image is too large (see [06](06-card-image-build.md)) |
| vendor logo | SPL did not take the card — check the `uboot` partition exists and starts at 16384 |
| our logo, nothing else | U-Boot read the card but `boot_android` refused the image — **check the boot image `id`** |
| our logo, kernel LED pulsing, nothing else | kernel alive; root mount or init. `rootwait` **hangs forever** rather than panicking when the root device never appears, so a hang with no reboot loop looks the same as a dead kernel |
| reboot loop | kernel panicked; `/BOOT-STAGE` says how far it got |
| kernel LED, then a *different* blink | init took over — success |

## Gotchas, in the order they bit

Each cost a hardware round-trip. All are fixed in the build scripts.

1. **Stale boot image `id`.** Editing the resource image without refreshing the
   header SHA1 makes U-Boot refuse the image — *after* it has already drawn the
   replaced logo from the same file.
2. **Root mounted read-only.** No `rw` on the command line, so init could not
   write its markers. Stock never noticed: its root is squashfs.
3. **`/init` is not searched for a disk root.** The kernel tries `/sbin/init`,
   `/etc/init`, `/bin/init`, `/bin/sh`. It found `/bin/sh` and sat in a shell on
   an invisible console. Needs `init=/init`.
4. **`console=tty0` renders nothing** — no framebuffer console in this kernel.
5. **The `work` LED's default trigger is `default-on`.** A steady LED is its
   resting state, so "LED on" proves nothing; only a *change* is signal.
6. **A near-blank logo is indistinguishable from no boot.** The vendor BMP is
   top-down (negative height); using that height unguarded in a scale
   calculation rendered 5x7-pixel text. Check with `--preview` before booting.
7. **An oversized resource image hangs U-Boot before display init** — the
   backlight never lights. See [06](06-card-image-build.md).
8. **`adbd` needs loopback.** It binds a TCP listener at start-up and treats
   failure as fatal, never reaching `usb_ffs_init`. No `lo`, no adb — and the
   only symptom is that adb silently does not appear.
9. **Boot timings are inflated when USB is attached.** U-Boot runs its charge
   animation (`/charge-animation`, `rockchip,uboot-charge`) before booting, and
   that time lands in the arch counter. Measure with USB unplugged; attach it
   afterwards.

## When to stop and open the case

If a failure survives the signals above — specifically, if the logo appears but
the kernel LED never does — the next step is UART on `ttyS2` at 1 500 000 baud
rather than another blind iteration. Everything upstream of the kernel prints
there and nowhere else.

That threshold was crossed once during this work and not acted on, at a cost of
several wasted boots; see the [investigation log](05-investigation-log.md).

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
