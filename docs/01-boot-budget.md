# my355 · Boot budget

Where the ~18 s from power-on to frontend actually goes, and what a BaseOS port can
realistically reclaim.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-20, on a unit
> running stock firmware with NextUI installed. Claims are *verified* (observed on
> hardware) or *inferred* (from binaries); retracted ones are kept in the
> [investigation log](05-investigation-log.md).

Rockchip's arch counter runs from SoC reset and U-Boot does not reset it, so kernel
timestamps are **power-on-relative**. This is confirmed by the reference serial log,
where U-Boot prints `Total: 3295.512/3340.136 ms` immediately before
`Starting kernel ...` and the first kernel line reads `[ 3.344904]`.

| phase | boundary | duration |
|---|---|---|
| bootrom + DDR training + SPL + BL31 + OP-TEE | → 0.39 s | **~0.39 s** |
| U-Boot | → 3.34 s (no card) / 4.29 s (card present) | **~2.9–3.9 s** |
| kernel → `/sbin/init` | 4.29 → 5.90 s | **1.61 s** |
| stock userland → frontend hand-off | 5.90 → 15.80 s | **9.90 s** |
| NextUI's own init | → ~18–20 s | ~2–4 s |

`launch.sh` (NextUI's entry point) starts at uptime 11.51 s = **15.80 s from power-on**.
That is the direct analogue of BaseOS's `boot-frontend-exec`, which is **2.96 s** on
RG40XXV ([05](../h700/05-runtime-power-network.md)).

## BaseOS, measured

With USB attached **after** power-on (see the caveat below), kernel stored gzipped:

| phase | stock | BaseOS | |
|---|---|---|---|
| pre-kernel (SPL + U-Boot) | 4.26 s from NAND | **3.14 s** from SD | −1.1 s |
| kernel → `/init` | 1.61 s | 1.57 s | |
| userland → frontend hand-off | **9.90 s** | **0.06 s** | `rcS` 1.43 → 1.49 |
| **total to hand-off** | **15.8 s** | **≈4.8 s** | **−11 s** |

Essentially the entire vendor userland — `mount -a` over SPI NAND,
`udevadm settle --timeout=30`, then eight serialised `S*` scripts — is gone, and
BaseOS now boots from SD *faster than stock does from internal NAND*.

> **Measuring caveat.** With a USB cable attached at power-on, U-Boot runs its
> charge animation (`/charge-animation`, `rockchip,uboot-charge`) before booting,
> and that time lands in the arch counter. It inflated readings to 7.18 s and
> 8.61 s. Measure with USB unplugged and attach it afterwards — adb hot-plug
> works on this device.

## Kernel compression: the big lever, measured

The vendor ships the kernel as a **raw 34.9 MiB arm64 `Image`** inside the boot
image, and U-Boot reads every byte off the card on each boot.

| stored as | size | share | pre-kernel |
|---|---|---|---|
| raw `Image` | 36 647 424 | 100% | 4.96 s |
| **gzip -9** | **12 991 358** | **35%** | **3.14 s** |
| lz4 -12 frame | 15 519 501 | 42% | 3.31 s |
| lz4 -9 legacy | 15 568 013 | 42% | does not boot — wrong framing |

**gzip saves 1.82 s** — over a third of the pre-kernel budget. The build asserts
`decompress(stored) == vendor kernel`, so the kernel is still the vendor's
byte-for-byte; only its storage changes. Default (`MY355_COMPRESS_KERNEL=gzip`).

### LZ4 boots, and loses

The first LZ4 card did not boot, which was read as "this U-Boot does not sniff
for LZ4 on the Android path". Wrong, and so was the reasoning: the evidence was
a byte-grep for the magic as a literal, but arm64 splits a 32-bit constant
across `movz`/`movk` bitfields, so that grep could not have found the check
either way. Disassembling the vendor U-Boot shows it:

```
android_image_get_comp(hdr) -> sniff(hdr + hdr->page_size)      @0xa29628
sniff(p):  zimage_parse_header(p) == 0     -> IH_COMP_ZIMAGE (6)
           lz4_valid_frame(p)              -> IH_COMP_LZ4    (5)  @0xaa83bc
           gzip_parse_header(p, 0xffff) >0 -> IH_COMP_GZIP   (1)
           lzma_check(p)                   -> IH_COMP_LZMA   (3)
           otherwise                       -> IH_COMP_NONE   (0)
```

`lz4_valid_frame` and `ulz4fn` accept only **frame** framing (`04 22 4d 18`)
with **independent blocks** — legacy `02 21 4c 18` is never tested for, and
linked blocks (`-BD`) get `-EPROTONOSUPPORT`. The failing card was legacy-framed:
its 15 568 013 bytes match `lz4 -9 -l` exactly. So `sniff` returned
`IH_COMP_NONE` and U-Boot jumped into the LZ4 header as if it were an `Image`.

`lz4 -12 -BI --no-frame-crc` boots, confirmed on hardware. It is also **0.17 s
slower than gzip**: 2.53 MiB more to read off the card costs more than the
faster inflate saves. gzip stays. (One cold boot each; the gap is small, but it
agrees with the size difference, so there is nothing to chase.)

`tools/rkbootimg.py` encodes the accept predicate and refuses to write a frame
this U-Boot would reject — the failure mode is a silent hang, so it is worth
making unrepresentable.

**zstd is not available.** No zstd magic appears in the disassembly as a
`movz`/`movk` immediate in either byte order, and there are no zstd strings:
this 2017.09 U-Boot predates `lib/zstd`. The four formats above are the set.

## Compared with H700

| | H700 | my355 |
|---|---|---|
| pre-kernel | ~1.5–2.5 s | **3.14 s** |
| kernel → init | 2.04 s | **1.57 s** |
| userland (`rcS`) | 0.55 s | **0.06 s** |
| to frontend hand-off | ~4.3–5.5 s | **≈4.8 s** |

The two ports are now in the same range. Our userland is ~9x faster and our
kernel phase is quicker; the bootloader remains our weaker half, and is where
any further gain has to come from.

Remaining levers, in order of size:

1. **Ship our own U-Boot.** The card already carries the `uboot` partition, so
   nothing stops putting a lean mainline build there instead of the vendor's
   2017.09 — which spends its time on AVB/trusty probing, a charge-animation
   path, GPT repair and a full DRM bring-up before it will boot anything.
2. **The kernel phase.** `rtl8733bu` probes for ~0.7 s of the 1.57 s, but making
   it a module would break "vendor kernel untouched".
3. **Shrink what U-Boot reads further.** The resource image is already rebuilt at
   442 880 bytes rather than the stock 943 616.

## Where the 9.9 s of userland goes

Sequential, all blocking, all before `S60mainui`:

- inittab `sysinit` `mount -a` (ext4 on SPI NAND) + `swapon` — init at 1.61 s uptime,
  `S00mountall`'s `mount-helper` does not start until 5.21 s
- `S10udev`: `udevd -d` + `udevadm trigger` ×2 + **`udevadm settle --timeout=30`**
- `S30dbus`, `S36load_wifi_modules`, `S40bluetooth`, `S40network`, `S41dhcpcd`,
  `S49ntp`, `S50dropbear`, `S50usbdevice`

This is exactly the class of work BaseOS deletes. Replacing the userland alone —
keeping the stock bootloader and kernel byte-for-byte — should land hand-off near
**5.5–6.5 s**, i.e. ~10 s reclaimed. Reaching H700-class numbers additionally requires
owning U-Boot, which costs another ~2 s.

## NextUI's vendor surface is small

`MinUI.pak/launch.sh` on `my355` touches only:

- `/sys/class/miyooio_chr_dev/joy_type` (in-kernel driver)
- `/usr/miyoo/lib` — three libraries (`libgamename.so`, `libshmvar.so`, `libtmenu.so`)
- `/usr/miyoo/bin/miyoo_inputd`

No `systemctl`, no `dmenu.bin` model detection, no vendor Bluetooth scripts. The whole
shim layer of H700 [01](../h700/01-rootfs-and-init.md) [backup & recovery](03-nand-backup-and-recovery.md) largely evaporates. The stock
`runmiyoo.sh` is already a NextUI shim baked into the squashfs, chaining to
`/mnt/SDCARD/.tmp_update/updater`.

---

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md)
