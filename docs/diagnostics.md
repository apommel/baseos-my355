# Diagnostics

How to debug a boot on a device that cannot tell you anything.

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
| **boot logo** | vendor path: U-Boot ran *and* read the card's `boot` partition. Mainline path: `rcS` is running | vendor path: `mkbootlogo.py` repaints the vendor BMP; only our card carries it. Mainline path: `fbsplash`, from ~2.4 s |
| **`fbsplash` message** | userspace is running and reached the frontend session | `INSERT SD CARD` and the update/expand bars are drawn from the rootfs |
| **the log** | how far init got, and what each step did | one file, `/data/baseos.log`, copied to `baseos.log` on the frontend card while it is mounted. Every script tags its own lines ([rootfs](rootfs.md)). Persistent, survives a power cut, and appended across boots, so the boot before the one that failed is still there |
| **adb** | `rcS` completed far enough to start `/etc/init.d/dev` | hot-plug works; no cable is needed at power-on |
| **crash record** | the previous boot panicked or never reached `rcK` | `rcS` copies `ramoops` to `/data/pstore/<date>/` and logs `pstore:`. It survives a warm reset only, so a long press loses it |

The crash record depends on a warm reset, which is why `rcS` sets
`kernel.panic=10`. This kernel has no lockup or hung-task detector, so a hang
that never panics still needs a long press. The ext4 mounts stay on the default
`errors=continue`: `errors=panic` would turn corruption read at boot into a
reboot loop, and a boot card lost at run time still falls to stock on the warm
reset, taking the record with it.

During bring-up a kernel-side LED heartbeat (`/leds/work
linux,default-trigger`, which `rkbootimg.py` could once set) was used and then
removed once the chain worked. It is a one-line addition to `build-image.sh`'s
`APPEND` if a future bring-up needs it again — see [history](history.md).

## Reading the card afterwards

The decisive trick. Put the BaseOS card in the **left slot**: it is not in
the SPL boot order, so the device boots **stock** from NAND instead,
and stock's kernel auto-mounts the card's ext4 partitions under `/media/`.
Everything the failed boot wrote is then readable over adb.

```sh
adb shell "grep mmcblk2 /proc/mounts"                    # find the mounts
adb shell "cat /media/sdcardN/baseos.log"                # how far init got
adb shell "dumpe2fs -h /dev/mmcblk2p3 | grep -E 'Last mounted on|Mount count'"
```

`Last mounted on: /` is conclusive proof the kernel mounted that partition as
root — which is how the final bug was found after the LED had already shown the
kernel was alive.

Stock also lets you test binaries against the *exact* kernel before trusting
them: `adb shell /media/sdcardN/bin/busybox` confirmed our static aarch64
busybox runs, ruling out the rootfs while the real bug was elsewhere.

## The mainline U-Boot path

On the mainline U-Boot path (the default; [U-Boot](uboot.md) Part 3) U-Boot
draws nothing: the panel stays dark until the kernel lights it and `rcS` draws
the logo at ~2.0 s, so a dark panel before then says nothing about whether the
boot worked. A debug build (`MY355_UBOOT_DEBUG=1`) makes up for it two ways.
The default release build (`0`) has neither: a failed boot is dark, then off.
Rebuild with `MY355_UBOOT_DEBUG=1` and flash it to see why.

**The charge LED** (`gpio0 PC2`, off from reset until the kernel's
`battery-charging` trigger claims it) marks U-Boot's stages once
`my355 charge` has let the boot through; before that, it shows the board
charging off ([U-Boot](uboot.md), *Charging while off*). Keep the charger
connected during bring-up so a failed boot cannot flatten the battery; a cable
at power-on only matters for timing boots.

| with the card in the right slot | means |
|---|---|
| stock boots | the SPL rejected our `uboot` FIT and fell through to NAND |
| dark, LED never lit | U-Boot died during its own init, before the boot script — the one blind case; the last change is the suspect |
| dark, LED stays lit | stuck finding or reading the `boot` FIT: read the log |
| dark, LED lit then off | the FIT was read; the hang is in `bootm` or the kernel: read the log |
| the device switches itself off | `bootm` refused the FIT, the read failed, or the CPU clock would not come back to 1104 MHz after decompression; the log says which |
| adb up, frontend running, panel black with the backlight on | the kernel's tree lacks the VOP2 plane assignment: dmesg says `use default plane mask` |
| battery far from what its voltage says | the fuel gauge was not reconciled: dmesg lacks `rk817-bat: initialized yet..`, or the log's `my355 fg:` line says why. It carries `cnt N mAh`, what the counter made of it, which is only ever reported unless `(charged while off)` appears — the one case where the counter is allowed to move the SOC ([U-Boot](uboot.md)) |

**U-Boot's console output** is recorded and written to the last 64 KiB of the
active `boot` partition just before hand-off, and again if the hand-off fails.
On BaseOS, `baseos-bootinfo log`. After a failed boot, from stock with the card in
the left slot:

```sh
adb shell 'n=$(cat /sys/class/block/mmcblk2p2/size); dd if=/dev/mmcblk2p2 bs=512 skip=$((n - 128)) count=128 2>/dev/null' | tr -d '\000'
```

That log belongs to the last boot that **reached the boot script**, which is not
necessarily the one that failed: a U-Boot that hangs in its own init saves
nothing, and the previous boot's log is what reads back. Tell them apart from
the same stock session: `dumpe2fs -h /dev/mmcblk2p3` gives root's `Last mount
time`, and a failed boot that never reached the kernel leaves it older than the
failure. A log identical to the last one read is stale too. Of the two LEDs
only the charge LED is ours to read; the `work` LED is lit during U-Boot too,
so it proves nothing about the kernel (2026-09-19).

The card is the only place a log can go. A failure that leaves the card
unusable, like the SDR50 attempts ([U-Boot](uboot.md), *The SD clock*), saves
nothing, and DRAM is no way around it: a record left in memory across U-Boot's
`reset` did not survive, and the boot looped (2026-09-19). Such failures need a
UART.

The first save happens before `bootm`, so a log that ends at the FIT read with
no `bootm` error after it means the hang is in `bootm` or the kernel — the shape
the 2026-08-24 failure would have had. A failed `bootm` returns, and the second
save then captures its error. Before the save, the debug script also logs
`mmc info` and `SDMMC0_CON0/1`, the card's drive and sample phases; `Bus Speed`
there is what U-Boot asked for, which until patch `0004` was twice what the card
got ([U-Boot](uboot.md)). `my355 fg:` records the battery state it found and
handed on. `baseos-bootinfo` alone prints U-Boot's bootstage timings on any
mainline boot that reached userspace.

## Failure signatures

| symptom | means |
|---|---|
| **backlight never lights** | U-Boot never reached display init. Prime suspect: the resource image is too large (see [card](card.md)) |
| vendor logo | SPL did not take the card — check the `uboot` partition exists and starts at 16384 |
| our logo, nothing else | U-Boot read the card but `boot_android` refused the image — **check the boot image `id`** |
| our logo, then nothing and no adb | kernel alive; root mount or init. `rootwait` **hangs forever** rather than panicking when the root device never appears, so a hang with no reboot loop looks the same as a dead kernel |
| reboot loop | kernel panicked: after `rcS` it sets `panic=10`; before, only with `panic=10` on the command line |
| logo, then adb appears | init took over — success |

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
   backlight never lights. See [card](card.md).
8. **`adbd` needs loopback.** It binds a TCP listener at start-up and treats
   failure as fatal, never reaching `usb_ffs_init`. No `lo`, no adb — and the
   only symptom is that adb silently does not appear.
9. **Boot timings are inflated when USB is attached.** U-Boot runs its charge
   animation (`/charge-animation`, `rockchip,uboot-charge`) before booting, and
   that time lands in the arch counter. Measure with USB unplugged; attach it
   afterwards.

## When to stop and open the case

If a failure survives the signals above — specifically, if the logo appears and
nothing else ever does — the next step is UART on `ttyS2` at 1 500 000 baud
rather than another blind iteration. Everything upstream of the kernel prints
there and nowhere else.

That threshold was crossed once during this work and not acted on, at a cost of
several wasted boots; see [history](history.md).
