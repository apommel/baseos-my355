# Decisions

The choices this port rests on, why each was made, and what is still open. A
decision recorded here is one that would be expensive to revisit — everything
else lives in the page for the thing it affects.

## Settled

### A mainline kernel, replacing the vendor's

Until the `feat/mainline` branch, BaseOS booted the vendor 5.10.160 kernel
byte-for-byte and replaced only the userland. That kept hardware support
complete for free, but froze the port on a 2025 BSP fork with no upstream
fixes, and the GPU on a g13p0 libmali with no Panfrost or PanVK.

| | vendor kernel (to 1.3.0) | **mainline — chosen** |
|---|---|---|
| kernel / DTB | 5.10.160 from `mtd2`, its DTB rewritten at build | Linux 7.2 from source, our own `rk3566-miyoo-flip.dts` |
| GPU | kbase g18p0, libmali g13p0 | ROCKNIX's `mali_kbase` (libmali g29p1) or Panfrost and PanVK, picked by `gpu=` |
| stock interface | native | a thin layer: device tree names, three small drivers, two patches, a `modetest` wrapper ([mainline-compat](mainline-compat.md)) |
| out of tree | everything | `mali_kbase`, `8733bu`, the panel, gamepad, DMC and suspend-config drivers |
| boot | `Run /init` 1.83 s, `nextui.elf` 2.40 s | 1.40 s, 2.33 s |

The two ran side by side while the mainline one was brought up; once it ran
NextUI, its emulators, sleep, WiFi, Bluetooth audio and HDMI at stock's power
draw, the vendor path was removed rather than kept beside it. Going back is a
matter of history: everything before the removal is in git.

What the kernel change does not change: the vendor BL31, OP-TEE and the SPL's
control tree stay byte-for-byte (the DDR blob is paired with that BL31), and
the stock-built userland stays unmodified, which is what the compatibility
layer is for. Its rule is in [mainline-compat](mainline-compat.md): mainline's
interface is the base, stock's a layer that forwards to it.

### Patch the user's preloader rather than ship one

The patched stock preloader works, is verified on hardware, costs nothing
measurable when no card is present, and leaves DDR scaling intact. Building our
own means writing first-stage code — the one region where a mistake costs a USB
recovery — for benefits that are largely gone:

1. **Distribution and provenance.** `tools/mkpreloader.py` redistributes nothing:
   it patches nine device tree properties into the user's own dump.
2. **Boot time — none to win.** 3.114 s pre-kernel against 3.118 s under
   GammaLoader's loader.
3. **Owning the boot order.** A custom SPL could list more devices, but the left
   slot is unreachable regardless: `spl_mmc_find_device` maps both
   `BOOT_DEVICE_MMC2` and `BOOT_DEVICE_MMC2_2` to mmc index 1, so both `dwmmc`
   nodes resolve to `fe2b0000` ([history](history.md)).

There is a fourth, decisive reason: the DDR blob is paired with the unit. One
shipped image forces ours onto every device, which is exactly how this unit came
to run a 2021 V1.10 blob against a V1.18-era BL31, and how it came to hang
intermittently on the boot logo until its own blob was restored.

Prerequisites, if it is ever attempted anyway: the Rockchip U-Boot 2017.09 tree,
a matching rkbin DDR blob, correct IDB/`RKNS` packaging (magic at `0x20000` for
SPI NAND, **not** sector 64 as on SD), emission of the `bootdev` ATAG, and a DDR
blob BL31 accepts. Each is individually known; together they are a real piece of
work, and every iteration is a preloader write.

### Mainline U-Boot, since 0.7.0

Replacing it needs no NAND write, because the card already carries the `uboot`
partition, and it fails safe: a bad FIT sends the SPL on to stock in NAND. The
1.2–1.7 s once projected for it is **refuted**, and the first build to boot
(2026-09-05) was 0.16 s *slower*, because it handed the kernel 816 MHz where the
vendor hands 1104. Eight changes later — that clock, a zstd kernel, the card
driven at the 50 MHz it only claimed to use, the data cache on before
relocation, the GPT held in the block cache, decompression at 1800 MHz, the
Flip's own control tree and the zstd decoder at `-O2` — it reaches `Run /init`
**1.8 s** ahead of the vendor path.

It costs the early boot logo — mainline U-Boot has no VOP2 driver, so `rcS`
draws it, on the panel at 2.00 s against ~1.0 s — and the charge screen (the
charge LED and the low-battery guard are kept). And it has to do by hand what the vendor
kernel silently relied on the vendor U-Boot for: the OP-TEE reservation, the
display plane assignment (without it the panel stays black under NextUI) and the
fuel gauge (without it the battery reads 0% when full). Each was found by its
failure, so there may be a fourth.

One of them turned into a gain. Giving each display a VOP2 window of its own
runs the panel and HDMI at the same time with independent content, and makes
hot-plug and hot-unplug work. Stock cannot: it disables the panel to use a TV,
and has to reboot to switch.

It became the default on 2026-09-19 and first shipped in 0.7.0, and is the
only path since the vendor kernel went. It replaces U-Boot proper and nothing
else: BL31, OP-TEE and the SPL's control tree stay the vendor's,
byte-for-byte. Its seven U-Boot patches and its control tree are ours to carry;
three of the patches — the RK3568 SD clock (an upstream bug), the data cache
before relocation and the 1608/1800 MHz CPU rates — are worth sending upstream.
The patches, the control tree and the measurements are in [U-Boot](uboot.md)
Part 3; tuning the vendor U-Boot from its device tree instead was tried and
measured at 22 ms (Part 1).

### No signing key for updates

A key would be a single point of failure for every update, and these images carry
no secrets. Integrity is a SHA-256 per region, verified by reading back what was
written ([the card](card.md)).

### Two cards, not one

BaseOS takes the right slot, because it is the only slot the SPL boots from, and
reads the frontend from a card in the left slot. One card works too — the boot
card's own FAT volume is the fallback — but two keeps games and saves on a card
that can be pulled, reformatted or replaced without touching the one that boots
the device. NextUI is slot-agnostic: nothing in `my355.sh` or
`MinUI.pak/launch.sh` names a block device ([rootfs](rootfs.md)).

### A read-only root

The kernel mounts the rootfs `ro`. Everything that changes at runtime already
lived elsewhere: `/data` for the log, keys, machine-id and update state; tmpfs
for `/tmp`, `/run` and `/var`; the card's `/userdata` bind for the frontend's
settings. NextUI never needed a writable root, since on stock it runs on
squashfs. What it buys: a power-off that skips `rcK` cannot dirty or corrupt
the OS, the root never replays a journal, a stray write fails with `EROFS`
instead of shadowing the card, and the running slot stays byte-identical to its
image ([rootfs](rootfs.md)).

## Open

- **spruceOS as a frontend.** Its card would be mounted and its `updater`
  executed, but whether it finds the userland it expects in the harvest is
  unchecked.
- **The harvest after Buildroot.** The build takes two files from it, the
  Bluetooth firmware, but the published bundle still carries `boot.img` and
  every other entry. Pruning them is a `harvest.list` edit plus a new bundle.
- **Buildroot for the userland.** Every library and program a frontend uses
  is built from source (`build-userland.sh`), with one toolchain, current
  releases and this device's options; the harvest supplies only the Bluetooth
  firmware. It replaced stock binaries over Debian's glibc: Debian's builds
  were prebuilt and quick, but configured for desktops (its SDL2 links X11,
  Wayland and PulseAudio, its dbus-daemon systemd), so the stock programs, on
  OpenSSL 1.1 and BlueZ 5.62, had to stay. What made source builds safe is
  knowing the interface: [what frontends need](rootfs-interface.md) measures
  it from a card, and `tools/abi_scan.py --baseline` checks a build against
  stock symbol by symbol. SDL2 is sdl2-compat over SDL3. Mesa still builds in
  `build-gpu.sh`, where Debian's LLVM saves building one.
