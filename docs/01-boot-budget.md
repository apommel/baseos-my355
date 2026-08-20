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
RG40XXV ([05](../05-runtime-power-network.md)).

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
shim layer of H700 [01](../01-rootfs-and-init.md) [backup & recovery](03-nand-backup-and-recovery.md) largely evaporates. The stock
`runmiyoo.sh` is already a NextUI shim baked into the squashfs, chaining to
`/mnt/SDCARD/.tmp_update/updater`.

---

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md)
