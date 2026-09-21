# History

How this port was found out, including the theories that turned out to be wrong
and the measurements later work superseded. Kept because the refutations are
load-bearing — each rules out a mechanism someone would otherwise retry.

Nothing here describes current behaviour. The working result is
[boot chain](boot-chain.md), [the card](card.md), [rootfs](rootfs.md) and
[boot time](boot-time.md).

## Change log

| date | event |
|---|---|
| 2026-08-19 | NAND backed up and verified over adb, no writes to device ([backup & recovery](recovery.md)) |
| 2026-08-19 | Exp. 1 — ROCKNIX card, right slot → stock booted |
| 2026-08-19 | Exp. 2 — added GPT partition `uboot` → stock booted; SPL disassembled |
| 2026-08-20 | Exp. 3 — device's own OP-TEE-bearing FIT on the card → stock booted; card-side causes exhausted ([investigation log](history.md)) |
| 2026-08-20 | Exp. 4 — patched `mtd1` (v1) → **ROCKNIX booted from SD**; fallback bug found; reverted |
| 2026-08-20 | Exp. 5 — patched `mtd1` (v2), fallback hardcoded → still hung with a non-bootable card; reverted ([investigation log](history.md)) |
| 2026-08-20 | GammaLoader disassembled — no raw-sector fallback; explains its ROCKNIX incompatibility ([SD boot](boot-chain.md)) |
| 2026-08-20 | Exp. 6 — **GammaLoader preloader only → all three cases correct; DDR scaling intact** ([SD boot](boot-chain.md)) |
| 2026-08-20 | ROCKNIX card re-flashed, `uboot` partition re-added → **ROCKNIX boots to UI** |
| 2026-08-20 | Card bring-up 1 — empty rootfs, `console=tty0` → unobservable; kernel has no framebuffer console |
| 2026-08-20 | Card bring-up 2 — stale boot image `id` found and fixed; U-Boot had been refusing the image after drawing our logo |
| 2026-08-20 | Card bring-up 3 — `rw` + `/BOOT-STAGE` markers; still nothing, cause still ambiguous |
| 2026-08-20 | Card bring-up 4 — kernel-side LED heartbeat proves the kernel runs; superblock shows `Last mounted on: /`, so root mounts |
| 2026-08-20 | Card bring-up 5 — `init=/init` added → **card boots to userspace. Chain complete.** |
| 2026-08-20 | Prepared inputs derived from the NAND backup; harvest list read from `/proc/<pid>/maps` on the running stock stack; closure verified |
| 2026-08-20 | Real rootfs built. Boot hangs with **no backlight** — pristine boot image's 943 KB resource; 465 KB boots. Isolated by swapping only the boot image |
| 2026-08-20 | adb failed: `cannot bind 'tcp:5037'`. Root cause **no loopback interface**; `adbd` treats the bind failure as fatal and never reaches `usb_ffs_init` |
| 2026-08-20 | **BaseOS boots with working adb.** `rcS` 50 ms, vendor binaries execute |
| 2026-08-20 | Resource image is now *built* rather than patched in place; pristine stock inputs restored |
| 2026-08-20 | fbsplash ported from `src/fbsplash.c`; `INSERT SD CARD` / `ADD FRONTEND TO SD CARD` restored |
| 2026-08-20 | Boot logo switched to the project artwork, backdrop subtracted to true black |
| 2026-08-20 | adb hot-plug confirmed working — no cable needed before power-on, unlike H700 |
| 2026-08-20 | Clean boot measured with USB unplugged: pre-kernel **4.96 s**, `rcS` 60 ms |
| 2026-08-20 | **Kernel stored gzipped: pre-kernel 4.96 s → 3.14 s.** Hand-off ≈4.8 s vs stock 15.8 s |
| 2026-08-20 | LZ4-legacy kernel tried → **does not boot**; reverted to gzip |
| 2026-08-21 | U-Boot disassembled: it **does** sniff for LZ4, but only frame framing with independent blocks. **LZ4 boots — and is 0.17 s slower than gzip.** gzip stays; no zstd in this U-Boot |
| 2026-08-20 | **NextUI launched from BaseOS** |
| 2026-08-22 | Stock SPL's SD failure explained: its DTB's `/pinctrl` node is an **empty skeleton** — the driver is compiled in, the node has no `compatible`, so no pin mux is ever applied ([SD boot](boot-chain.md)) |
| 2026-08-22 | Full boot measured over adb: power-on → NextUI input **7.62 s**, against ~18.5 s stock — the stock half **superseded 2026-08-23**, see below ([boot budget](boot-time.md)) |
| 2026-08-22 | Pre-kernel budget decomposed with a padded-kernel boot: **U-Boot init 1.21 s, read 1.19 s at 10.9 MB/s, inflate 0.35 s** ([boot budget](boot-time.md)) |
| 2026-08-22 | The 0.40 s silent kernel gap identified as `tracer_init_tracefs` (0.383 s) — a kernel config choice, not reachable from the DTB |
| 2026-08-22 | Replacing U-Boot evaluated and **shelved**: the boot path needs no reverse engineering, but mainline U-Boot has no VOP2 driver, so a splash means writing one ([U-Boot](uboot.md)) |
| 2026-08-22 | **Bug found and fixed:** `rk-kernel.dtb.hdmi` was never patched and still carried the stock `root=/dev/mtdblock3`. U-Boot selects it when `g_miyoo_use_hdmi` is set, so BaseOS would not have booted on that path |
| 2026-08-22 | The vendor U-Boot takes its control tree from our `rk-kernel.dtb` (`USING_KERNEL_DTB`), so it is tunable without being replaced — but the tunings measured **22 ms** on a 3.14 s budget and were removed. The 10.9 MB/s read is not a UHS fallback ([U-Boot](uboot.md)) |
| 2026-08-22 | Reported: **intermittent hang on the boot logo**, logo turning pixelated, on both SD and NAND. Open — see below |
| 2026-08-22 | `unbrick/MiniLoaderAll.bin` is a *second* Rockchip generic loader (Dec 2021, DDR V1.16) with the identical nine `/pinctrl` properties — the patch now has two independent references. The defect is one missing `u-boot,dm-spl` tag on `&pinctrl` in Miyoo's DTS |
| 2026-08-22 | This unit's `mtd5` **proven to come from the unbrick `update.img`**, not the factory: its `FlashBoot`, descrambled with the keystream recovered from the package's own plaintext DDR blob, is byte-identical to the on-device SPL ([SD boot](boot-chain.md)) |
| 2026-08-22 | **Retracted:** the empty `/pinctrl` is not a regression in Miyoo's later SPL builds — it is in *every* Miyoo preloader sampled (Nov 02 and Dec 12 2024, two units). GammaLoader works because it is **Rockchip's generic `MiniLoaderAll.bin`** left behind by `rkdevtool`, not a Miyoo build; neither firmware image contains a preloader at all ([SD boot](boot-chain.md)) |
| 2026-08-22 | **Stock-derived preloader written to `mtd5` and verified on hardware.** Stock boots with no card, BaseOS boots from SD, DMC healthy on the restored DDR **V1.18** — Experiment 7 below |
| 2026-08-22 | Stock-derived preloader settled: the IDB carries **plain SHA-256, no signature**, and the fix is **+180 bytes of `/pinctrl` properties into 649 bytes of slack** — SPL code and DDR V1.18 byte-identical, boot order already SD-first. Built and self-verifying (`tools/mkpreloader.py`), not flashed ([SD boot](boot-chain.md)) |
| 2026-08-23 | **Stock measured end to end: power-on → NextUI frame 31.50 s**, not the ~18.5 s quoted until now. The 15.8 s hand-off was right; NextUI's own start, guessed at 2–4 s, is **15.7 s**. A stopwatch had said 28–32 s all along ([boot budget](boot-time.md)) |
| 2026-08-23 | **Retracted:** "the `launch.sh` prologue is identical on stock". It is **0.89 s on BaseOS against 12.45 s on stock** — a bigger saving than the whole vendor userland we delete, from a script we neither own nor changed. Read as unattributable at the time — kernel log and syslog silent throughout, and I/O, `nextval.elf`, `amixer`, `modetest`, `sync` and card walks each excluded on the device — **superseded 2026-09-17, see below** ([boot time](boot-time.md)) |
| 2026-08-23 | BaseOS re-measured after Bluetooth: first frame **7.98 s** (was 7.62), hand-off **5.05 s** (was 4.91), `rcS` 0.07 → 0.21 s. The attribution given here was **wrong** — see below ([boot budget](boot-time.md)) |
| 2026-08-23 | Clock method pinned: `/proc/uptime` and printk timestamps differ by a per-boot offset, measured by writing an uptime reading into `/dev/kmsg` and reading the printk timestamp back. Needed on stock, whose squashfs root has no `jbd2` anchor ([boot budget](boot-time.md)) |
| 2026-08-23 | **Retracted:** "the system bus is only ~20 ms; the rest is the first writes to `/data`". The error was reading `dbus-daemon`'s `starttime` as when `rcS` reached it — `system.conf` has `<fork/>`, so it is the daemonised *child*, after the config parse and socket bind. Bracketed with two free `mark` calls instead: **`dbus-daemon --system` is 0.14 s of a 0.20 s `rcS`**; the `/data` writes are 0.01 s ([boot budget](boot-time.md)) |
| 2026-08-23 | `rcS` critical path cut 17 forks → 10: `mkdir /data/bluetooth` and `/data/cfg` were dead, `/etc/machine-id`, `/mnt/sdcard` and both mount points are baked into the image, breadcrumbs use ash builtins instead of `/bin/cut`. Worth ~0.02 s — correct, but not the tenth of a second it aimed at |
| 2026-08-23 | Hand-off **4.98 s**, first frame **7.93 s** — best so far, though part of the gain is a 0.06 s kernel phase that is boot-to-boot variance, not ours |
| 2026-08-23 | Preloader patch reimplemented in **BusyBox only** and run on the device: 2.2 s, output byte-identical to `tools/mkpreloader.py`, fails closed on corrupt/short/foreign/already-patched input ([SD boot](boot-chain.md)) |
| 2026-08-23 | Card installer packaged as a 28 KiB `miyoo355_fw.img` and driven end-to-end through stock's own gate and `miyoo_fw_update` extraction — **dry run, nothing flashed** ([SD boot](boot-chain.md)) |
| 2026-08-23 | Official 250527 `runmiyoo.sh` is **byte-identical** to this unit's `runmiyoo-original.sh`; neither firmware's update script writes `mtd5`, so the preloader patch survives a Miyoo firmware update |
| 2026-08-23 | Distribution settled: **patch in place, ship no preloader binary** — the DDR blob is paired with the unit, and more than one stock SPL build exists ([SD boot](boot-chain.md)) |
| 2026-08-23 | Stock automounts with usbmount: two mountpoints per slot for three filesystems, allocated by lock race. **Five trials, no reliable winner** — no correlation with slot, LBA, entry number or cache state ([SD boot](boot-chain.md)) |
| 2026-08-23 | **Retracted:** "on a cold boot the rootfs always wins the first mountpoint", read off two trials. A cold boot in the right slot gave it to the FAT and the rootfs none, so the installer was never found. It ships on all three filesystems ([SD boot](boot-chain.md)) |
| 2026-08-23 | Installer run for real off a card at boot (left slot, so stock still booted): stock's gate fired, the payload unpacked, `mtd5` read as `620648c2…`, refused as already patched, **nothing written**, no reboot ([SD boot](boot-chain.md)) |
| 2026-08-23 | Installer confirmed idempotent on **GammaLoader's preloader** too — its container passes all four IDB hashes and is refused on the `/pinctrl` guard, so an existing GammaLoader install is never replaced ([SD boot](boot-chain.md)) |
| 2026-08-23 | Stock preloader **restored** over adb to test the installer for real: `flash_erase` + `nandwrite` rc=0, readback byte-identical to `mtd5-spl.img` (`36d663ef…`), 0 ECC failures, 0 corrected bits, 0 bad blocks |
| 2026-08-23 | Installer extracted back out of the built card and rehearsed against the restored NAND: derived `620648c2…`, the image known to boot, and stopped before the erase ([SD boot](boot-chain.md)) |
| 2026-08-23 | First live install attempt **did not fire**: the rootfs lost the mountpoint race, so `/media/sdcard0` was the FAT and the gate found no image. Nothing written, device unharmed |
| 2026-08-23 | **Preloader patched for the first time from a card**, unattended: `36d663ef…` → `620648c2…`, flash attempt 1, readback verified. The full path works ([SD boot](boot-chain.md)) |
| 2026-08-23 | Bug: the installer did not reboot afterwards. `/media/sdcard0` is a symlink to `/mnt/sdcard`, which is the name `/proc/mounts` carries, so the device lookup found nothing. Only `sdcard0` is a symlink, so it bit the right-hand slot alone. Fixed with `pwd -P` |
| 2026-08-23 | **Full chain proven from a fresh card**: stock booted, gate fired, `mtd5` `36d663ef…` → `620648c2…`, readback verified on attempt 1, rebooted itself into BaseOS. Four seconds, on battery, backup and log on the FAT ([SD boot](boot-chain.md)) |
| 2026-08-23 | The card's FAT would not mount on macOS: `mkfs.vfat` chose 4 KiB clusters for a 63 MiB volume, giving **16092 clusters against the 65525 a FAT32 requires**. Linux mounts it regardless; macOS validates and refuses. Fixed with `-s 1` ([card image](card.md)) |
| 2026-08-24 | BaseOS could only start a NextUI card **some stock install had already initialised**: `.tmp_update` is not at the top of the base zip but under `miyoo355/app/`, and it is the zip's own `my355.sh` — reached through stock's `CUSTOMER_DIR` — that copies it up. `nextui-session` now does that staging itself. Stock reads **`miyoo355` only**; the zip's `miyoo/` is the Mini/A30 directory, left untouched ([rootfs](rootfs.md)) |
| 2026-08-24 | A card inserted **after** boot was never picked up: `rcS` is `::sysinit:` and mounts once, and `nextui-session` only waited on that mount. It now mounts too, as on H700 — and releases the fallback `rcS` leaves on `/mnt/SDCARD` when the left slot was empty at boot ([rootfs](rootfs.md)) |
| 2026-08-24 | `Bootlogo.pak` checked against BaseOS: **harmless**. No `mtdparts` on BaseOS's cmdline, so `/proc/mtd` is one unnamed `spi-nand0` and the pak's `"boot"` lookup fails before any read; `flashcp` is absent besides. Wrong target anyway — BaseOS boots its logo from `mmcblk1p2`, not NAND |
| 2026-08-24 | First mainline U-Boot card (branch `custom-uboot-v1`): dark screen, no kernel. The kernel was never told OP-TEE is resident at `0x08400000` — the vendor U-Boot hides it by splitting `/memory`, mainline does not — and overwrote it. Fixed with a `/reserved-memory` node ([U-Boot](uboot.md)) |
| 2026-09-05 | **Mainline U-Boot boots.** First printk 3.134 → **2.682 s**, but kernel → `Run /init` 1.523 → **2.095 s** on every payload: **0.16 s slower** to `rcS`. zstd in a FIT **1.60 s slower** than gzip. **Retracted:** the 1.2–1.7 s projection for replacing U-Boot, and the 0.2–0.3 s for zstd ([U-Boot](uboot.md)) |
| 2026-09-15 | NextUI `da3165de` aligned its stock hook with spruceOS's and moved the `/userdata` binds and the right-slot check into `.tmp_update/my355.sh`. BaseOS's session no longer sets up `/userdata` — NextUI on the Flip is beta-only, so there are no older releases relying on it — and is renamed `frontend-session`: mounting the card and running `updater` is the entry point both hooks share. The slot check misses on BaseOS only because `/proc/mounts` lists `/mnt/SDCARD`, so the card must stay mounted there ([rootfs](rootfs.md)) |
| 2026-09-16 | **Retracted:** "`tracer_init_tracefs` is not reachable without rebuilding the kernel". The vendor kernel honours `initcall_blacklist=`. Skipping it, `ohci_platform_init` (OHCI serves no device; the WiFi/BT chip is high-speed on EHCI) and `alpu_init` takes the kernel phase **1.52 s → 0.81 s** with the kernel unchanged. First frame **5.99 s**, hand-off **3.95 s**. WiFi and Bluetooth verified ([boot budget](boot-time.md)) |
| 2026-09-16 | `bootargs` outgrew the vendor's 100 bytes; `rkbootimg.py` now grows the FDT property instead of refusing |
| 2026-09-16 | SDR104 on the left slot tried and **reverted**: the card hung during init and the session fell back to the boot card's frontend. **Retracted:** that slot 1 "shares `vccio_sd`". Its `vqmmc-supply` says so, but its pins are in I/O domain `vccio4`, a fixed 3.3 V ([boot budget](boot-time.md)) |
| 2026-09-16 | Kernel gzip now encoded with **libdeflate -12**: 12 991 358 → 12 504 834 bytes, same format. One cold boot each put the first printk at 2.897 s before and 2.856 s after (−41 ms, prediction −45 ms); four libdeflate boots agree to 2 ms ([boot budget](boot-time.md)) |
| 2026-09-16 | `crypto@fe380000` enabled so U-Boot could hash the boot image in hardware: first printk 2.858 / 2.856 s on two cold boots against 2.856 s without — **no gain, reverted**. Kernel side harmless ([U-Boot](uboot.md)) |
| 2026-09-16 | `quiet` and `cpufreq.default_governor=performance` on the command line; `frontend-session` drops to `ondemand` with no frontend. Two cold boots: hand-off **3.87 s** (was 3.91–3.93), first frame **5.89 s** (was 5.99–6.02) ([boot budget](boot-time.md)) |
| 2026-09-16 | `rcS` trimmed: update scripts only run during a trial, dbus and the random seed in the background, `frontend-session` waits for the bus. About 30 ms ([boot budget](boot-time.md)) |
| 2026-09-16 | **Every boot replayed both ext4 journals**: busybox init unmounts nothing, and `rcK` tried to unmount while `adbd` and the frontend still held the volumes. `rcK` now stops everything first (SIGTERM, 1 s, SIGKILL), unmounts in reverse order and remounts `/` read-only; `rcS` remounts `/` `noatime`. Replays cost up to 0.2 s per boot and are gone ([boot budget](boot-time.md)) |
| 2026-09-16 | Boot card replaced (the original was failing). Hand-off **3.72–3.74 s**, first frame **5.72–5.75 s** on two cold boots ([boot budget](boot-time.md)) |
| 2026-09-17 | **The 12.45 s `launch.sh` prologue attributed**, by instrumenting it on stock: nearly all of it is `nextval.elf` faulting the vendor SDL/Mali stack in from the squashfs in SPI NAND, purely because it is the first binary to run. On BaseOS the same libraries come from ext4 on the boot card at SDR104, hence 0.89 s. **Retracted:** "unattributed", and the exclusion of `nextval.elf` — that 0.60 s "cold" figure was measured post-hoc with the squashfs pages already cached ([boot time](boot-time.md)) |
| 2026-09-17 | **One log.** Eight destinations — `/data/boot.log`, `baseos-boot.log` and `baseos-session.log` on the card, `/tmp/frontend-session.log`, `/data/expand.log`, `/data/usb-gadget.log`, `/data/shutdown.log`, `/data/update/log` — collapsed into `/data/baseos.log`, copied to `baseos.log` on the frontend card, with each line tagged by the script that wrote it. `log()` and `mark()` live in `/usr/share/baseos/log.sh`, sourced by all six writers, and the file appends across boots with `rcS`'s boot record delimiting them — following upstream BaseOS, whose own A/B over five boots per variant found no boot-speed difference between logging to RAM and to the card. An every-boot rotation was tried first and dropped: its two `mv` forks measured 1.5 ms on `/data` and 3.0 ms on the card's FAT, and it read `rcS` **0.08 s** against the 0.06 s baseline. Appending instead gives **0.06 and 0.07 s** on two cold boots and hand-off **3.73 s** — so the ~15 ms that rotation could not explain was the freshly reinstalled `/data` those boots ran on, not the log ([rootfs](rootfs.md)) |
| 2026-09-18 | **Stale harvests caught**, following upstream BaseOS: `source.json` pins the harvest's hash, which an old tar still matches after `manifest/harvest.list` changes, so a list edit could build without the new path. `source_manifest.py verify` now also checks the tar holds exactly the listed paths — both directions, exclusions included — and since every build, `fetch-prepared.sh` and `cache-pack.sh` already call it, no new call sites were needed ([rootfs](rootfs.md)) |
| 2026-09-18 | **Mainline U-Boot rebuilt** from the first build's lessons: `boot` found by name (the fixed sector broke A/B), bootstage written into the kernel's tree, the console saved to the card and stages on the charge LED — no UART needed. Boots; three cold boots at 816 MHz agree to 0.2 ms. **Retracted:** "vdd_cpu is a TCS4525 at 0x1c, at 850 mV" — the Flip has an RK8600 at 0x40, powering on at 1000 mV. **Verified:** the vendor hands the kernel 1104 MHz (stock serial log) ([U-Boot](uboot.md)) |
| 2026-09-18 | Mainline hands the kernel **1104 MHz**: first printk 2.723 → **2.537 s**, `Run /init` **3.440 s** against the vendor's 3.58 s ([U-Boot](uboot.md)) |
| 2026-09-18 | **Retracted:** "zstd is 1.60 s slower than gzip". U-Boot's own decoders, timed on the device: `-mstrict-align` (all of arm64) costs zstd 2x and `ZSTD_LIB_MINIFY` 1.6x more; an 8 MiB window 1.4x. Fixed and tuned, 1,982 → **352 ms** against gzip's 428 ([U-Boot](uboot.md)) |
| 2026-09-18 | zstd booted: decode **347 ms** against gzip's 447, `start_kernel` **−87 ms**, `Run /init` **3.239 s** ([U-Boot](uboot.md)) |
| 2026-09-18 | **Retracted:** "U-Boot reads the card at 50 MHz, and 12.0 MB/s is what that allows". The RK3568's SD controller halves its input clock; the kernel provides for it (`clk_sdmmc0` 297 MHz for a 148.5 MHz card) and so do U-Boot's px30, rk3308, rk3328 and rk3399 clock drivers, but not rk3568's — so the card ran at 25 MHz, capped at 12.5 MB/s, while `mmc info` printed 50 MHz. Patch `0004`: read **1,063 → 536 ms** (23.8 MB/s), card init 289 → 202 ms, first printk **1.837 s**, `Run /init` **2.663 s**, **0.92 s** ahead of the vendor path. U-Boot's timings agree to 0.1 ms over four cold boots. Upstream master still has the bug ([U-Boot](uboot.md)) |
| 2026-09-18 | `flash-card.sh` from upstream replaces the raw `dd` recipe. Its disk guard was rekeyed: upstream refuses `Internal: Yes`, a field current `diskutil` no longer prints, and accepts `Device Location: External`, which a mounted disk image also reports. Now: physical removable media only ([the card](card.md)) |
| 2026-09-19 | **Mainline path: NextUI black with the backlight on**, card in at boot or inserted later. NextUI ran and the VOP scanned out its frame, but on the panel's port the kernel had defaulted to the RK3566's mirror windows (`use default plane mask`): the vendor U-Boot writes `rockchip,plane-mask`/`primary-plane` into the kernel's tree every boot and mainline does not. `mkfit.py boot` now writes the vendor's policy — main windows `0x15` to the DSI port, mirrors `0x2a` to HDMI. Earlier timing boots had no frontend card, so none could show it ([U-Boot](uboot.md)) |
| 2026-09-21 | **Charging while off: the charge LED is back.** It was dark after the switch to mainline, but the battery was charging: a unit charged while off booted with `CHRG_STS` *terminated* at 4.16 V and the counter up 18 mAh (`charged while off`). The LED is a SoC pin, and mainline powered straight back off when the charger woke the PMIC (`ROCKCHIP_RK8XX_DISABLE_BOOT_ON_POWERON`). `my355 charge` now keeps U-Boot up instead, as stock does, lighting it while the PMIC reports charging and powering off when full or unplugged; the power key boots. A shutdown with the charger in restarts into it with `reboot charge` (`/usr/sbin/poweroff`, `rcK`, `rebootmode`), since a PMIC switched off with the charger in is never woken. The gauge is synced on the way out, so a charge while off is no longer lost to the counter's decay, and `SYS_CAN_SD` is cleared first, as the vendor U-Boot does at probe. Reviewed against the vendor's `charge_animation.c`: it stays up when full, boots on a long press and idles in PSCI suspend; this powers off, boots on any press and idles in WFE ([U-Boot](uboot.md)) |
| 2026-09-21 | **0% after a night off at 84%, on the vendor rule.** Not the rule: `my355 fg` never reached it (`gauge state unusable, left to the kernel`), and the kernel took its halt path (`system halt last time... cap: pre=2505, now=0`) and restarted from 0. After ~11 h the counter had fallen below zero, setting bit 31 of `Q_PRES` — `CAP_INVALID` — and an early exit on that bit, left over from the first version, bailed out before the decision. The vendor's `rk817_bat_get_capacity_uah()` returns 0 for such a counter and its rule is guarded `now_cap > 0`, so a negative counter is just another fall: the saved state is kept. The port had copied the decision but not its input handling. Now it does both, and the other early exit went with it: an out-of-range `fcc` is replaced by the design capacity or `qmax`, as the vendor's `rk817_bat_get_fcc()` does, instead of handing the kernel its halt path. Only an unreadable PMIC or a reconnected battery (`BAT_CON`, the kernel's own first-power-on path) still leave it to the kernel ([U-Boot](uboot.md)) |
| 2026-09-20 | **The counter does not survive a power-off; the rule is the vendor's — only a *rise* is believed.** Three more offs measured: 4h20m cost 112 mAh, ~9.4 h cost 2,670, 70 min cost 284. No rate, no bound, always downward, so nothing to extrapolate or threshold. Two wrong answers before the right one. **Retracted:** a 40-point counter-vs-voltage threshold and the constant ~258 mAh/h drift rate behind it, both of which rested on reading `OFF_CNT` as minutes — a *timed* one-hour off reads **6**, so it steps ~10 minutes, making the vendor kernel's own `pwroff_min >= 30` really about five hours. **Retracted:** taking `PWRON_VOL` against the `ocv_table` instead, verified only on cold boots at ~100% where the top of the curve is unambiguous; the first cold boot in the middle of it put a cell the counter had tracked to **75% at 92%** (4023 mV while *delivering* 331 mA per `PWRON_CUR`, so ~4056 mV open-circuit against the table's 3883 for 75% — the wrong sign for an IR error). Reading the real [`fg_rk817.c`](https://github.com/rockchip-linux/u-boot/blob/next-dev/drivers/power/fuel_gauge/fg_rk817.c) rather than inferring it from `strings` settled it: `rk817_bat_not_first_pwron()` never reads the voltage on this path. It takes the counter only when `now_cap > pre_cap + 10` — charge gained while off — and otherwise keeps the SOC and capacity the kernel last saved, re-seeding the counter from them. That gets all six recorded boots right with no OCV table, calibration, IR term or `OFF_CNT`, leaving the command **+13 lines** over its original at **13.6 ms** ([U-Boot](uboot.md)) |
| 2026-09-20 | **Mainline path: battery at 11% after a night switched off**, on stock too. Not drain: `PWRON_VOL`, latched by the PMIC at power-on, read **4203 mV**, the charger was terminated at 6 mA, and NextUI's battery log jumps 100% → 11% across the off with nothing between. Not the `SYS_CAN_SD` leak upstream documents either — `0xe6` bit 7 was clear, and at the ~8 mA the [Zetarancio notebook](https://github.com/Zetarancio/Miyoo-Flip-Mainline-Linux-Reverse-Engineering/blob/main/docs/miyoo-flip-power-off-investigation.md) measures for the leaky state, a night costs ~3 points, not 89. What failed was the coulomb counter, which `my355 fg` trusted: `FG_INIT` suppresses the kernel's own recalibration from resting voltage along with the halt path it is set for, so the guard left with the bug. The display had been climbing back at 1% per 72 s — the vendor driver's charge-finish walk — so it would have healed in 107 minutes ([U-Boot](uboot.md)) |
| 2026-09-19 | **Mainline path: battery at 8% when full.** The gauge knew better (coulomb counter 3,000 of 3,000 mAh, 4.19 V); the displayed SOC had been restarted from 0 by the kernel, which reads charge gained while off as a halted session and resets to an `rsoc` it has not computed yet. The vendor U-Boot's fuel-gauge driver reconciles the gauge and sets `FG_INIT` every boot, which is why stock never shows it. `my355 fg` does the same, plus a cross-check that replaces a saved SOC more than 10 points from the counter's: 11.993 → 99.900% on the first boot, `rk817-bat: initialized yet..`, 13.5 ms ([U-Boot](uboot.md)) |
| 2026-09-19 | **Mainline path to a first NextUI frame: 4.09–4.10 s**, timed by polling the DRM state for a `nextui.elf` framebuffer on a plane, since this path has no `drm_logo` to free. NextUI starts at 3.26–3.27 s against the vendor path's 4.19–4.23 ([boot time](boot-time.md)) |
| 2026-09-19 | A first per-initcall diagnostics build **hung dark after relocation**: `reserve_bootstage()` sizes the relocated block from the names recorded so far, the extra marks made before `reloc_bootstage()` overran it into U-Boot's just-relocated device tree. Read back from stock with the card in the left slot: root last mounted before the flash, the saved log from the previous boot. Fixed with slack in the reservation ([U-Boot](uboot.md)) |
| 2026-09-19 | **U-Boot's 570 ms of early init broken down**: `initf_dm` 288 ms, `serial_init` 222, `print_resetinfo` 22, the rest ~40, against 38 ms for the same binding and probing after relocation. **Retracted:** "the quartz64-a tree's size is what makes early init slow; a Flip tree is the fix", and the follow-up "instruction fetches are uncached" — enabling the I-cache early changed no step by 0.5 ms. The data cache was the cause: patch `0005` turns it on before relocation, as stm32mp does, and early init takes **40 ms**. `start_kernel` 1,803 → **1,274 ms**; over five cold boots `Run /init` **2.09–2.12 s**, NextUI starting **2.69–2.73 s**, first frame **3.53–3.57 s** — 1.5 s ahead of the vendor path to NextUI ([U-Boot](uboot.md)) |
| 2026-09-19 | **Mainline U-Boot becomes the default.** `build-all.sh` builds it; `MY355_UBOOT=vendor` builds the vendor path. Accepted costs: no boot logo, no low-battery guard or charge animation, no `.hdmi` tree variant ([decisions](decisions.md)) |
| 2026-09-19 | **Mainline path: a boot logo from `rcS`**, `fbsplash 0` into `/dev/fb0` when the bootloader handed the kernel none. First try, ~0.1 s visible: the panel first showed an image at 2.99 s, and nothing lit the backlight before NextUI. The boot script now powers the panel (gpio0 PC7) so the kernel's power-up waits can go (160/200/200 → 0/20/0 ms, image at 2.43 s), and `rcS` lights the backlight and mounts debugfs for `launch.sh`'s duty carry-over. Still black: NextUI's `my355.sh` zeroes `/dev/fb0` at ~2.3 s, found by `baseos-frameprobe`'s new display log. With that line skipped, the logo shows from 2.43 s to NextUI's first frame. **Retracted:** Part 2's "cheaper variant" of a U-Boot that stages the logo without lighting the panel; and "the kernel side could show a logo at ~2.9 s", which needed all three fixes ([U-Boot](uboot.md)) |
| 2026-09-19 | **`MY355_DIAG=1` is back**, meaning the boot-timing aids this work needed: per-initcall bootstage marks in U-Boot (`tools/uboot/patches-diag/`) and a first-frame probe in the rootfs (`overlay-diag/`). `baseos-bootinfo timeline` prints a boot's milestones on the printk clock, with SD card detection and journal replays, the two known causes of kernel-phase outliers ([U-Boot](uboot.md)) |
| 2026-09-19 | **Mainline path: the logo on the panel at 2.29 s**, from 2.43 s: the panel init sequence's 250 ms wait after sleep-out is now 120 ms. Stable over 12 warm and several cold boots. Dropping the panel regulator's `vin-supply` was tried first and gave nothing: the DSI host defers on its panel at 1.73 s (link order) and this kernel retries deferred devices only at ~2.02 s ([U-Boot](uboot.md)) |
| 2026-09-19 | **A WiFi race cost ~0.3 s on half the boots**, on both paths: with `rootwait` the root mount waits out any probe in flight, and the RTL8733BU's ~0.3 s efuse read starts within ms of the card being ready. Root at ~2.49 s instead of ~2.20 s in 11 of 20 boots. `usbcore.authorized_default=0` plus authorization from `rcS` in the background: 12 of 12 on time since, WiFi up each time ([boot time](boot-time.md)) |
| 2026-09-19 | **Card init at ~200 ms instead of ~77 ms on most boots, attributed**: one SDR104 tuning read on the edge of the card's bad phase window waiting out the controller's ~113 ms data timeout. Not CPU idle latency, the first guess. `rockchip,desired-num-phases = 36` makes it 6 of 22 boots instead of 13 of 16, on both paths; a fixed phase would remove it but only for one card ([boot time](boot-time.md)) |
| 2026-09-19 | **U-Boot's `mmc dev 1`: 202 → 53 ms, hand-off 1.274 → 1.124 s.** Not the card (init 40 ms, ready at the first ACMD41 poll): creating a block device per partition looked up all 128 GPT slots, each re-reading the 20-block entry array, which U-Boot's 8-block cache limit never kept. `blkcache configure 32 32` in the boot script. `Run /init` 1.95–1.98 s, first frame 3.16–3.19 s (warm) ([U-Boot](uboot.md)) |
| 2026-09-19 | **SDR50 in U-Boot tried and shelved.** It read the FIT at 100 MHz on a warm reboot, but the card must be power-cycled back to 3.3 V for the kernel, which cannot power it (`vcc_sd`'s `enable-gpio` is not read by `regulator-fixed`), and U-Boot's power cycle is a no-op (`vcc3v3_sd` is reference-counted, `regulator-boot-on` holding one). Cold boots failed in card init with no log ([U-Boot](uboot.md)) |
| 2026-09-19 | **Decompression at 1800 MHz: hand-off 1.124 → 1.004 s.** `bootm` in its steps, the clock raised to 1800 MHz at the OPP table's L0 1150 mV for `bootm loados` and back to 1104 before `prep`/`go`, as the kernel sets 900 mV before cpufreq. Patch `0006` adds Linux's 1608/1800 MHz rows. 1416 MHz first: 1.058 s. `Run /init` 1.83–1.85 s, first frame 2.93–2.98 s (warm) ([U-Boot](uboot.md)) |
| 2026-09-19 | **The Flip's own U-Boot control tree: hand-off 1.004 → 0.978 s.** quartz64-a's tree matched the Flip's rails, but its IO-domain map fed vccio4 from `vcc_1v8`: U-Boot set it to 1.8 V mode on the Flip's 3.3 V rail, until the kernel corrected it at 1.74 s. The Flip tree (`tools/uboot/dts/`) describes the boot slot, five RK817 rails, the IO domains and the UART. Init after relocation 59 → 36 ms, 289 → 242 devices; `Run /init` 1.81–1.82 s over five warm reboots ([U-Boot](uboot.md)) |
| 2026-09-19 | **SDR50 tried again and dropped.** On the Flip tree, with `vcc_sd` cut through decompression and a high-speed retry. A warm reboot read the FIT at SDR50 and hung in the kernel: the repowered card did not answer. Every cold boot failed the 1.8 V switch in the first card init, and the forced high-speed retry switched too (`mmc_get_op_cond()` asks for 1.8 V from the board's capabilities, not the forced mode). No log survives either failure, the card being the only place to write one; a record kept in DRAM across `reset` was lost, and the boot looped. Dropped without a UART ([U-Boot](uboot.md), *The SD clock*) |
| 2026-09-19 | **Release U-Boot by default.** `MY355_UBOOT_DEBUG=0`: no console record on the card and no charge-LED stages, 7 ms faster; `1` brings them back for a failed boot ([diagnostics](diagnostics.md)) |
| 2026-09-20 | **HDMI works, and both displays run at once** — cold-plug, hot-plug and hot-unplug. The RK3566 has three real VOP2 windows; Cluster1, Esmart1 and Smart1 only mirror the other three, so the vendor's all-mains/all-mirrors split left whichever display held the mirrors scanning out the *other* one's buffer at its own stride: on a TV, the boot logo duplicated and torn, and nothing NextUI drew. Proved by writing red into the panel's buffer and watching the TV turn red. Now a main window each — panel `0x30` (Smart0), HDMI `0x0f` (Esmart0, which also scales). A first attempt assigning only the three real windows was silently discarded (`all windows should be assigned … use default plane mask`), so every window must be given out and `set_vop2_plane_masks` refuses a split that is not exhaustive. Clocks and DDR unchanged: both ports were always fetching, a mirror simply fetched the wrong address. Stock could never do this — its `rk-kernel.dtb.hdmi` disables the panel to run the TV alone, which is why it rebooted to switch and could not hot-plug ([U-Boot](uboot.md)) |

## SD boot investigation — result: **the stock SPL cannot boot from SD**

Two hardware experiments, then static analysis of the SPL binary.

### Experiment 1 — ROCKNIX card, right slot

`ROCKNIX-RK3566.aarch64-20260710-Specific.img.gz` written to a card, `extlinux.conf`
repointed to `rk3566-miyoo-flip.dtb`, `quiet` removed so the kernel log would render on
the panel via `console=tty0`. Card alone, right slot.

**Result: booted stock from NAND.** Kernel entry at 4.293 s.

The card's layout is correct for Rockchip's convention — `RKNS` IDB at sector 64,
`u-boot.itb` at **sector 16384 (`0x4000`)**, partition 1 starting at LBA 32768. The FIT
is structurally equivalent to the stock one:

| | stock `mtd1` FIT | ROCKNIX `u-boot.itb` |
|---|---|---|
| external-data FIT | yes | yes |
| `firmware` | `atf-1` | `atf-1` |
| `loadables` | `uboot, atf-2..6, optee` | `u-boot, atf-2..6` |
| `fdt` | `fdt` (rk3568-evb) | `fdt-1` (rk3566-quartz64-a) |
| sha256 hash nodes | yes | yes |
| ATF SRAM loads | `0xfdcc1000 / ce000 / d0000` | identical |

### Experiment 2 — add a GPT partition named `uboot`

Hypothesis: Rockchip's SPL locates U-Boot on MMC by GPT partition **name**, and
ROCKNIX's card has only `system` and `storage`. A partition named `uboot` was added
spanning LBA 16384–24575 — a partition-table edit only, no payload moved.

Verified on the card afterwards: entry 3 `name='uboot'`, LBA 16384..24575, and
`d00dfeed` present at sector 16384.

**Result: booted stock from NAND again.** Kernel entry at 4.259 s.

### Static analysis — what the SPL actually does

Disassembly of `mtd5` (capstone; ADRP targets are computable without knowing the load
address because the image is page-aligned in the file, so
`target_fileoff = (site & ~0xFFF) + imm*4096 + imm12`).

`spl_mmc_load_image` at `0x31558`:

```
0x3157c  bl 0x314b8          spl_mmc_find_device(&mmc, boot_device)
                               boot_device 1     -> mmc index 0  (sdhci)
                               boot_device 2 | 3 -> mmc index 1  (dwmmc@fe2b0000)
                               else -> "spl: unsupported mmc boot device."
0x3158c  bl 0x45a4c          mmc_init(mmc)   -> "spl: mmc init failed with error: %d"
0x315c0  bl 0x2e758          spl_boot_mode()
0x2e758:   mov w0, #1 ; ret      <-- ALWAYS MMCSD_MODE_RAW
0x3160c  bl 0x38d64          part_get_info_by_name(desc, "uboot", &info)
0x31610  tbz w0,#31 -> 0x31694   found    -> load FIT from info.start
0x31614                          not found-> print "spl: partition error"
0x31620  mov x2, #0x4000     ... and load FIT from RAW SECTOR 0x4000 anyway
```

Two consequences:

1. **`spl_boot_mode()` is unconditionally `MMCSD_MODE_RAW`.** The FS and EMMCBOOT paths
   are unreachable.
2. **Both the named-partition path and the failure path converge on sector `0x4000`.**
   The raw-sector fallback existed all along, so experiment 2's hypothesis was not just
   wrong — it could not have been the blocker. Experiment 1 should already have worked.

Therefore the failure is **upstream**, in `spl_mmc_find_device()` or `mmc_init()`.

### Why: the SPL has no way to power the slot

The Flip's SD rail is switched. From the stock kernel DTS:

```dts
dwmmc@fe2b0000 { vmmc-supply = <&vcc_sd>; vqmmc-supply = <&vccio_sd>; ... };
vcc-sd  { compatible = "regulator-fixed"; regulator-name = "vcc_sd";
          enable-gpio = <&gpio0 5 GPIO_ACTIVE_LOW>; enable-active-low;
          regulator-boot-on; min = max = 3300000; };
LDO_REG5 { regulator-name = "vccio_sd"; 1800000..3300000; always-on; boot-on; };
```

The stock SPL's device tree is a **generic Rockchip RK3568 EVB tree**. Its
`dwmmc@fe2b0000` node has **no `vmmc-supply`, no `vqmmc-supply`, no `bus-width`, no
`cap-sd-highspeed`**, and there is no io-domain setup (stock U-Boot proper does that
later — `io-domain: OK`).

And this is not merely a device-tree omission — **the regulator driver is not in the
SPL binary at all**:

| string | in `mtd5` |
|---|---|
| `gpio-controller`, `u-boot,dm-spl` | present |
| `regulator-fixed` | **absent** |
| `regulator-name`, `regulator-boot-on`, `regulator-min-microvolt` | **absent** |
| `vmmc-supply`, `vqmmc-supply` | **absent** |

So **patching the SPL's embedded DTB cannot work** — there is no `DM_REGULATOR` /
fixed-regulator code to consume the property.

Confirmation from the other side. ROCKNIX's own SPL (idbloader on the card, sector 458)
declares exactly what is missing, on the *same GPIO pins* as the Flip:

```dts
mmc@fe2b0000 { vmmc-supply  = <&regulator_vcc3v3_sd>;
               vqmmc-supply = <&vccio_sd>;
               cd-gpios = <&gpio0 4 GPIO_ACTIVE_LOW>;
               bus-width = <4>; cap-sd-highspeed; sd-uhs-sdr104; };
regulator-vcc3v3-sd { compatible = "regulator-fixed";
                      gpio = <&gpio0 5 GPIO_ACTIVE_LOW>;
                      regulator-name = "vcc3v3_sd"; regulator-boot-on; };
chosen { u-boot,spl-boot-order = "/mmc@fe2b0000", "/mmc@fe310000"; };
```

Quartz64-A and the Miyoo Flip share the SD power-enable GPIO (`gpio0` pin 5,
active-low) and card-detect (`gpio0` pin 4) — which is why a *generic* RK3566 ROCKNIX
U-Boot works on this device at all.

### What the SPL does and does not contain

Verified by locating each string and checking whether it falls inside the embedded DTB
(`0x685d8`/`0xc85d8`, 6058 bytes each) or in code/rodata — a compatible string in
code/rodata is a **driver match table**, i.e. the driver is compiled in.

| capability | evidence | present |
|---|---|---|
| dw_mmc (SD controller) | `rockchip,rk3288-dw-mshc` @ `0x5f0af` (rodata) | **yes** |
| sdhci (eMMC) | `snps,dwcmshc-sdhci` @ `0x5f18b` (rodata) | **yes** |
| SFC / SPI-NAND | `rockchip,sfc` @ `0x5fc1c`, `spi-nand` @ `0x5dca2` (rodata) | **yes** |
| DT props parsed | `bus-width`, `max-frequency`, `fifo-depth`, `non-removable` | yes |
| DT props **not** parsed | `cap-sd-highspeed`, `cd-gpios`, `broken-cd`, `disable-wp`, `sd-uhs-*` | — |
| regulator / `vmmc-supply` | `regulator-fixed`, `regulator-name`, `vmmc-supply` all absent | **no** |
| io-domain | `io-domain`, `rockchip,io-domain`, `vccio` absent | **no** |

The SFC result matters beyond diagnosis: a Rockchip 2017.09-vintage SPL **can** do
SPI-NAND boot, which is what the fall-back-to-stock leg of [investigation log](history.md) requires.

### Experiment 3 — stock's own FIT on the card (2026-08-20)

The strongest possible card-side test. Written to the test card:

- sector 16384 (`0x4000`), inside the GPT partition named `uboot`:
  **`mtd1-uboot.img` verbatim** — the device's own Rockchip-format FIT, *including*
  `os = "op-tee"`, i.e. the exact bytes this SPL loads successfully on every boot
- a GPT partition named `boot` at LBA 4292608 holding **`mtd2-boot.img` verbatim**

Both verified byte-exact on the card by slice-wise md5 before booting.

**Result: `storagemedia=mtd`. Booted from internal NAND.** Kernel entry 4.266 s; NAND
hashes unchanged. The kernel enumerated `mmcblk1p3` (4 MiB) and `mmcblk1p4` (38 MiB),
confirming the card was exactly as intended.

### Mechanism: card-side causes are exhausted

Three hypotheses have now been tested and refuted on hardware:

| # | hypothesis | refuted by |
|---|---|---|
| 1 | SPL locates U-Boot by GPT partition name `uboot` | Exp. 2 — added it, no change. Disassembly then showed a raw-sector `0x4000` fallback exists anyway |
| 2 | SPL cannot power the SD rail (no `vmmc-supply`/regulator) | GammaLoader's working SPL has no regulator support either |
| 3 | The SD chain must be Rockchip-format with OP-TEE | Exp. 3 — supplied the device's own OP-TEE-bearing FIT, no change |

The SPL was given *the exact bytes it loads every boot*, at *the exact sector its own
code falls back to*, inside *a partition with the exact name its own code looks up* —
and still did not take it. **The SPL does not successfully read the card at all.** The
failure is at MMC device/init level, before any FIT is examined, which is precisely
where the disassembly above localised it: `spl_mmc_find_device()` or `mmc_init()`.

**No card layout can fix this.** Every remaining variable is on the device side.

That GammaLoader exists at all is corroborating: it ships a *replacement* preloader
(SPL `2017.09-ga1f6fc00a0-210413`, Apr 2021, DDR `V1.10`) even though the stock boot
order already lists the SD first — which only makes sense if the stock SPL's SD path
does not work. The plausible reading is that Miyoo's later SPL builds broke or disabled
it.

**Caveat on adopting GammaLoader directly:** its bundled `boot.img.gz` is *not* this
unit's kernel (12 916 788-byte kernel and 944 128-byte resource, vs 36 647 424 and
465 408 in `mtd2` here). Installing it replaces the preloader **and** downgrades the
boot partition to a foreign kernel underneath a 2025-06-27 rootfs.

### Settled (2026-08-22): the SPL's device tree has no pinctrl provider

Both remedies below were overtaken by a binary comparison of the two SPLs' device
trees. The stock SPL's `/pinctrl` node is an **empty skeleton** — no `compatible`,
so no pinctrl device binds, so `dwmmc@fe2b0000`'s `pinctrl-0` is never applied and
the SD pins are never muxed. The driver is compiled in; the DT cannot reach it.
Full evidence and the `fdtgrep` mechanism that produced it are in
[SD boot](boot-chain.md).

This closes the question the three experiments left open, and confirms
independently that no card layout could ever have worked. What was still open when
it was written:

1. **UART on `ttyS2` @ 1 500 000.** Still the cheapest falsifier — the prediction is
   `spl: mmc init failed with error: …`, not `could not find mmc device`.
2. **Bypass the SPL entirely.** Done as Experiments 4 and 5; U-Boot proper does
   reach the card, at the cost of an `mtd1` patch that hung on non-bootable cards.

### The left slot is unreachable regardless

`spl_mmc_find_device` maps `BOOT_DEVICE_MMC2` (2) **and** `BOOT_DEVICE_MMC2_2` (3) to
**mmc index 1**. Both `dwmmc` entries in the boot order therefore resolve to
`dwmmc@fe2b0000`. `dwmmc@fe2c0000` also has no `pinctrl` in the SPL DT. The left slot
cannot be an SPL boot source on this firmware.

---

## Stock U-Boot in `mtd1` — **proven to reach the SD card**

The SPL is a dead end ([investigation log](history.md)), but the next stage is not. Stock U-Boot already contains
`distro_bootcmd`, `bootcmd_mmc1`, `scan_dev_for_boot`, `scan_dev_for_extlinux` and
`sysboot`, and `boot_targets` already begins with `mmc1`. The only reason none of it
fires is ordering: the SPL passes a `bootdev` ATAG (`Bootdev(atags): mtd 1`), so
`boot_android mtd 1` runs first and succeeds, and the `run distro_bootcmd` at the tail
is never reached.

No environment backend is compiled in (`Loading Environment from`, `env_mmc`,
`env_nand`, `env_sf`, `env_fat`, `uEnv.txt` all absent), so the environment cannot be
overridden from a card. Changing it means patching `mtd1`.

### Experiment 4 — patched U-Boot flashed to `mtd1` (2026-08-20) — **SD boot works**

Applied to `mtd1`, all length-preserving in the compiled-in default environment plus
one flag in the control FDT, with the affected FIT `hash/value` nodes recomputed:

| | offset | change |
|---|---|---|
| `bootcmd` | `0xee48f` | `distro_bootcmd` moved to the front |
| `boot_targets` | `0xeecc7` | `mmc1 mmc0 mtd2 mtd1 mtd0 usb0 pxe dhcp` → `mmc1` |
| `cd-gpios` flags | `0x1f3bdc` | `0` (ACTIVE_HIGH) → `1` (ACTIVE_LOW), matching ROCKNIX for the same pin |

Written with `flash_erase /dev/mtd1 0 0 && nandwrite -p /dev/mtd1 …` from the running
stock system (`mtd1` has **0 bad blocks**, so `mtdblock` reads and `nandwrite` writes
are equivalent). Readback verified byte-exact.

**Result: ROCKNIX booted from the SD card.** Stock U-Boot located
`/extlinux/extlinux.conf` on the card, loaded `/KERNEL` with
`rk3566-miyoo-flip.dtb`, and started a mainline kernel.

**This is the load-bearing finding of the whole investigation.** The SPL cannot reach
the SD, but U-Boot proper can — it does the PMIC and io-domain init
(`PMIC: RK8170`, `io-domain: OK`) that the SPL never does. An SD-bootable BaseOS for
this device is therefore possible, at the cost of a `mtd1` patch.

### The bug in that first patch, and the fix

The patch was described as fail-safe. It was not. With **no card**, `mmc dev 1` fails,
`devtype` is untouched, and stock boots — correct. But with a card that has **no
`extlinux.conf`** (e.g. a NextUI card):

```
mmc_boot = if mmc dev ${devnum}; then setenv devtype mmc; run scan_dev_for_boot_part; fi
                                      ^^^^^^^^^^^^^^^^^^ clobbers devtype
```

`mmc dev 1` succeeds, `devtype` becomes `mmc`, the scan finds nothing, and the trailing
fallback `boot_android ${devtype} ${devnum}` has silently become `boot_android mmc 1`.
It looks for a `boot` partition on the *card*, finds none, and **hangs**. Observed on
hardware: no card → stock boots; NextUI card → stuck on the boot screen.

`mtd1` was restored from backup (verified `eaadbe9d…`) and NextUI recovered.

**Fix — hardcode the fallback target so it cannot be clobbered:**

```
bootcmd=run distro_bootcmd;boot_android mtd 1;boot_fit;bootrkp;
```

55 characters against the original 70, so it still patches in place with trailing
padding. `mtd 1` is exactly what the ATAG supplies today.

Built as `mtd1-uboot-sdfirst-v2.img` from the pristine original,
**md5 `ba5b8207b523a1a3de84fde4c9e0720b`**, 157 bytes changed, all 9 FIT hashes verify.
**Not yet flashed.**

### Experiment 5 — corrected `bootcmd` (v2) — fallback still hangs

`mtd1-uboot-sdfirst-v2.img` (md5 `ba5b8207b523a1a3de84fde4c9e0720b`, built from the
pristine original, 157 bytes changed, 9/9 FIT hashes verify), with

```
bootcmd=run distro_bootcmd;boot_android mtd 1;boot_fit;bootrkp;
```

Flashed and verified byte-exact; all other partitions unchanged.

| card | result |
|---|---|
| none | stock boots normally, wall-clock essentially unchanged |
| ROCKNIX (GPT, 2 GB FAT) | boots from SD, then stalls (see [port plan](decisions.md)) |
| NextUI (MBR, **115 GB FAT32**) | **hangs indefinitely** — 2 minutes, no change |

So the `devtype` clobbering was *not* the cause: v2 fixes it and the symptom is
unchanged. The hang is specific to *a card being present that carries no
`extlinux.conf`*, and it is a genuine hang rather than slowness.

> **Retracted:** an earlier reading of this experiment claimed a ~20 s pre-kernel
> regression, from `dmesg` reporting kernel entry at 24.29 s against a 4.26 s baseline.
> Stopwatch measurement to the stock UI showed no such change. The kernel timestamp is
> not trustworthy across a warm reboot (the arch counter is not reset), and the
> wall-clock observation supersedes it.

**Unexplained.** One untested observation: the two cards differ in partition scheme
(GPT vs MBR) and by two orders of magnitude in volume size (2 GB vs 115 GB). U-Boot
2017.09's FAT/partition handling on a 115 GB FAT32 volume is a candidate, but this is a
hypothesis and has not been tested.

`mtd1` was restored from backup; all six partitions re-verified against the manifest.

### What actually triggers an SD boot

Not a partition named `boot` — that is `boot_android`, a different mechanism. The
distro path is:

```
scan_dev_for_boot_part : bootable partition (else partition 1), filesystem U-Boot knows
scan_dev_for_boot      : /extlinux/extlinux.conf | /boot/extlinux/extlinux.conf
                         | boot.scr.uimg | boot.scr
```

So a BaseOS card needs a **FAT partition carrying `extlinux/extlinux.conf`, a kernel
and a DTB** — considerably simpler than building Android boot images.

### Recovery

`back_to_bootrom` is present in the SPL alongside
`SPL: failed to boot from all boot devices`; a bad `mtd1` should return control to the
bootrom for USB MASKROM without opening the case. Untested. Beneath that sit `xrock`
and the verified `mtd1-uboot.img` backup ([backup & recovery](recovery.md)). In practice the revert was done entirely
over adb from the running stock system.

### Delivery: the vendor's own card-flash path

`runmiyoo-original.sh` looks for `miyoo355_fw.img` on either card, compares a
model/version header against `/usr/miyoo/version` (`20250627233124`), and runs
`/usr/miyoo/apps/fw_update/miyoo_fw_update`, which does:

```sh
dd if=miyoo355_fw.img of=/tmp/miyoo_fw_version.txt bs=128 count=1
dd if=miyoo355_fw.img of=/tmp/miyoo_update.sh     bs=512 skip=1 count=8
```

— the update script is embedded at sector 1 and **executed as root**, so the image
author controls exactly which partitions are written. Card image layout:
`uboot` @ `0x100000`, `boot` @ `0x800000`, `rootfs` @ `0x5000000`; the preloader is not
part of a card image. This is how NextUI already modifies stock, and is a safer
delivery vehicle than hand-rolled `nandwrite` for anything distributed to users.

### Fallback: replace the preloader

Only if the U-Boot route proves insufficient. Strictly worse: a built SPL, the Rockchip
`bootdev` ATAG to emit, a DDR blob that may mismatch stock BL31 and disable DMC, and a
first-stage mistake is the one failure with a real chance of needing disassembly.

**GammaLoader is not a drop-in** for this unit: alongside a replacement preloader it
flashes a `boot.img` whose kernel is 12 916 788 bytes with a 944 128-byte resource,
versus 36 647 424 / 465 408 in this unit's `mtd2` — i.e. it downgrades the kernel
underneath a 2025-06-27 rootfs.

## Experiment 6 — GammaLoader preloader only (2026-08-20) — **works**

Only `mtd5` written, from the running stock system; GammaLoader's own installer was
**not** run, so its foreign `boot.img` (a different kernel: 12 916 788 B against this
unit's 36 647 424) never touched `mtd2`. Readback byte-exact, md5 `2252285d…`.
`mtd0`–`mtd4` unchanged, so stock U-Boot, BL31, kernel and rootfs were all preserved.

| card | result |
|---|---|
| none | stock → MainUI. Pre-kernel `[ 4.313678]` against a 4.26–4.29 s stock baseline — no measurable cost |
| ROCKNIX + `uboot` partition | **boots from SD** |
| NextUI (no `uboot` partition) | falls through to stock, normally |

Two risks settled by it. `/proc/cmdline` reported `storagemedia=mtd`,
`root=/dev/mtdblock3` on the fallback path, so **GammaLoader's SPL does emit the
Rockchip `bootdev` ATAG** stock U-Boot needs. And DDR scaling survived the older blob —
V1.10 (2021) against this unit's BL31 (TF-A v2.3, Jun 2023) still gave all four FSPs,
`dmc_ondemand`, and no `loader&trust unmatch`.

## Experiment 7 — patched stock preloader (2026-08-22) — **works**

Replaces Experiment 6. `mtd5` rewritten with this unit's own Dec-2024 SPL and DDR
V1.18, patched only to restore `/pinctrl` ([SD boot](boot-chain.md)). Battery 99% on
USB power, 0 bad blocks; `flash_erase` + `nandwrite` both `rc=0`; readback byte-exact
(md5 `ccc27973…`), 0 ECC failures, 0 corrected bits.

Stock boots with no card; the BaseOS card boots from SD (`storagemedia=sd`,
`root=/dev/mmcblk1p3`) into NextUI. Pre-kernel **3.114 s** against 3.118 s under
GammaLoader. DMC healthy on V1.18: four FSPs, `dmc_ondemand`, ATF `0x102`, no
`loader&trust unmatch`.

## Retracted conclusions

Recorded because each cost a hardware experiment, and because the pattern matters:
each was a plausible mechanism asserted before it was tested.

| claim | why it was wrong |
|---|---|
| The ROCKNIX artifact was the "generic" build, not device-specific | ROCKNIX ships one image per SoC family; per-device selection is the extlinux `FDT` line. The quartz64-a U-Boot DTB is expected. |
| The *stock* SPL locates U-Boot only by GPT partition name | Disassembly showed a raw-sector `0x4000` fallback. (True of GammaLoader's SPL — [SD boot](boot-chain.md) — which is why the tip works there.) |
| The SPL cannot power the SD rail | GammaLoader's working SPL has no regulator support either. The actual cause is pin mux, not power — the rail is on by default at reset ([SD boot](boot-chain.md)). |
| The SD chain must carry OP-TEE | Exp. 3 supplied an OP-TEE-bearing FIT with no change; Exp. 6 boots a ROCKNIX FIT that has none. |
| The v1 `bootcmd` patch was "fail-safe by construction" | `mmc_boot` clobbers `devtype`; a card with no bootable content hung the device. |
| v2 added a ~20 s pre-kernel regression | Kernel timestamps are unreliable across warm reboots; stopwatch showed no change. |
| GammaLoader's preloader costs ~2.9 s of boot time | That sample had a non-bootable card inserted. With no card it is 4.31 s — within noise of stock. |
| A pulsing/steady `work` LED distinguishes success from failure | Its default trigger is `default-on`; a steady LED is the resting state. Only a *change* is signal. |
| `console=tty0` would show kernel messages on the panel | `# CONFIG_FRAMEBUFFER_CONSOLE is not set` — it renders nothing. The H700 doc records the same for its kernel, and it had already been read. |
| The empty-rootfs smoke test would prove the boot chain | It could not: with no console, "kernel panicked at init" and "kernel never started" look identical. Two rounds were spent on tests that could not distinguish success from failure. |
| The `work` LED steady meant the kernel was dead | Its default trigger is `default-on`. Twice read as a failure signal when it carried no information. |
| "No boot logo" meant U-Boot did not run | The logo had rendered near-blank — the vendor BMP is top-down and a negative height fed the scale calculation. The instrument was broken, so the reading was void, not negative. |
| Pre-kernel time had regressed to 7–8 s | USB was attached, so U-Boot ran its charge animation first and that landed in the arch counter. Measure with USB unplugged. |
| The rootfs "is not working perfectly well" | It was working: `rcS` ran to completion and wrote persistent state. Only the USB gadget had failed. |
| This U-Boot does not sniff for LZ4 on the Android path | It does — `lz4_valid_frame` is called straight out of `android_image_get_comp`. The evidence was a byte-grep for the magic as a literal, but arm64 splits a 32-bit constant across `movz`/`movk` bitfields, so the grep could not have found the check either way. The failing card was **legacy**-framed, the one format the sniffer ignores. |
| LZ4 would beat gzip because it inflates faster | Measured: 3.31 s against gzip's 3.14 s. It is 2.53 MiB larger, and the extra card read outweighs the faster inflate. |
| The measured gzip saving implied a ~13 MB/s read with free decompression | That was the degenerate root of `23.6/R − D = 1.82`. Both guesses at the split were then wrong: a padded-kernel boot measured **R = 10.9 MB/s and inflate = 0.35 s**, not the 8–10 MB/s and 0.5–1.1 s this file went on to assume ([boot budget](boot-time.md)). Estimating a two-unknown split from one equation stayed wrong twice; the fix was a third boot that moved one variable. |
| `nextval.elf` is not the 12.45 s prologue — it is 0.60 s cold | It is nearly all of it. The "cold" figure was taken post-hoc on a running device, where the squashfs pages it needed were already in the page cache, so it measured the warm path of the one step that is only expensive cold. The cost is the vendor SDL/Mali stack coming off SPI NAND, and it falls on whichever binary `launch.sh` starts first ([boot time](boot-time.md)). |
| The ROCKNIX stall was *not* the storage-partition collision | It was. The theory was abandoned when removing the blocking partition didn't help — but ROCKNIX's resize runs **once**, so the damage persisted. Correct diagnosis, wrong inference from the retest. |

## Resolved — intermittent hang on the boot logo (2026-08-22 → 2026-09)

**Symptom.** Randomly, a boot stopped on the boot logo and never proceeded, and
**the logo became pixelated**. Seen on both the SD and the stock NAND path.

**Cause: GammaLoader's DDR blob.** `mtd5` is read by the bootrom on every boot,
whichever medium the SPL then picks, so it was the only changed component common
to both failing paths — and it is where DRAM is brought up. While GammaLoader was
installed, a 2021 **V1.10** blob was training this unit's LPDDR4 against a
V1.18-era BL31:

| | build | DDR blob |
|---|---|---|
| this unit's own `mtd5` | SPL 2017.09 (Dec 12 2024) | **V1.18 `f366f69a7d`, typ 23/07/17** |
| GammaLoader, as installed | SPL 2017.09 (Apr 13 2021) | **V1.10, 20210810** |

The pixelation was the informative part: blocky corruption of an image that was
drawn correctly is what DRAM bit errors look like, not what a stalled bootloader
looks like, and DDR training re-runs every boot and can land differently each
time.

**Fixed by Experiment 7** — restoring this unit's own V1.18 blob as part of
switching to the patched stock preloader. The hang has not recurred since, which
is also one of the reasons the port patches the user's own preloader instead of
shipping one ([boot chain](boot-chain.md)).

The PMIC theory was never supported: on a healthy boot the battery read `Full`,
4.159 V, `health=Good`, thermal zones 41.9 / 39.4 / 18.8 °C.

**Still worth doing if a silent hang ever returns:** the kernel registers
`ramoops` (`0xf0000@0x110000`), which survives a warm reset, but nothing mounts
`pstore`, so a panic leaves no readable record. Mounting it in `rcS` would make
the next one self-documenting.

## Measurement history

The tables [boot time](boot-time.md) replaced, kept because every later figure is
measured against them.

### BaseOS end to end, 2026-08-23 (pre-SDR104, pre-initcalls)

`uptime + 3.295 = seconds from power-on`, kernel stored gzipped with zlib.

| phase | duration | at power-on |
|---|---|---|
| bootrom + DDR + SPL + BL31 | 0.39 s | 0.39 |
| **vendor U-Boot, from the card** | 2.74 s | 3.13 |
| kernel → `Run /init` | 1.51 s | 4.64 |
| busybox init → first `rcS` breadcrumb | 0.08 s | 4.73 |
| **`rcS`** | 0.20 s | 4.93 |
| **frontend hand-off** | 0.03 s | **4.98** |
| NextUI `launch.sh` prologue | 0.89 s | 5.95 |
| `nextui.elf` init → first frame | 1.98 s | **7.93** |

Of that `rcS`, **`dbus-daemon --system` was 0.14 s** and the other three phases
0.06 s together.

### One change per column, to 2026-09-16

| | 2026-08-24 | + initcalls | + libdeflate | + `quiet`, governor | + `rcS`, clean shutdown¹ |
|---|---|---|---|---|---|
| boots | 1 | 1 | 2 | 2 | 2 |
| first printk | 3.13 s | 2.90 s | 2.86 s | 2.86 s | 2.85 s |
| `Run /init` | 4.65 s | 3.71 s | 3.67–3.68 s | 3.66 s | 3.58 s |
| `rcS` | 0.12 s | 0.16 s | 0.16–0.17 s | 0.14–0.15 s | **0.06 s** |
| **frontend hand-off** | — | 3.95 s | 3.91–3.93 s | 3.87–3.88 s | **3.72–3.74 s** |
| `nextui.elf` start | — | 4.47 s | 4.43–4.44 s | 4.35–4.36 s | 4.19–4.23 s |
| **first NextUI frame** | 6.87 s | 5.99 s | 5.99–6.02 s | 5.89 s | **5.72–5.75 s** |

¹ On a different boot card; the original was replaced after it started failing.
The new one reads 59 MB/s against the old one's 63 MB/s, so the columns are
comparable, but it detects 85 ms sooner at SDR104.

Two things in that sequence are **not explained** by any of the changes: pre-kernel
is 0.24 s shorter than on 2026-08-24 for no reason found (stable since — four
boots read 2.856–2.858 s), and `rcS` was 0.16 s against 0.12 s before the trimming,
most likely the update scripts added in between.

### What SDR104 bought, 2026-08-24

| phase | 2026-08-23 | SDR104 | Δ |
|---|---|---|---|
| pre-kernel | 3.13 s | 3.13 s | 0.00 |
| kernel → `Run /init` | 1.51 s | 1.52 s | +0.01 |
| **`rcS`** | 0.20 s | **0.12 s** | −0.08 |
| **hand-off → `nextui.elf` start** | 1.00 s | **0.52 s** | −0.48 |
| **`nextui.elf` init → first frame** | 1.98 s | **1.52 s** | −0.46 |
| **power-on → first frame** | **7.93 s** | **6.87 s** | **−1.06** |

Nothing before the kernel moved, and nothing was expected to. The estimate
written beforehand was 0.3–0.6 s; the outcome was 1.06 s, because the phase that
gained most was the one attributed to NextUI — `nextui.elf` lives on the game
card, but every library it links lives in our rootfs on the boot card.

### Kernel storage formats, measured

| stored as | size | pre-kernel |
|---|---|---|
| raw `Image` | 36 647 424 | 4.96 s |
| gzip -9 (zlib) | 12 991 358 | 3.14 s |
| **gzip, libdeflate -12** | **12 504 834** | **2.86 s** |
| lz4 -12 frame | 15 519 501 | 3.31 s |
| lz4 -9 legacy | 15 568 013 | does not boot — wrong framing |

**LZ4 boots, and loses.** The first LZ4 card did not boot, which was read as
"this U-Boot does not sniff for LZ4". Wrong, and so was the reasoning: the
evidence was a byte-grep for the magic as a literal, but arm64 splits a 32-bit
constant across `movz`/`movk` bitfields, so that grep could not have found the
check either way. Disassembly shows it:

```
android_image_get_comp(hdr) -> sniff(hdr + hdr->page_size)      @0xa29628
sniff(p):  zimage_parse_header(p) == 0     -> IH_COMP_ZIMAGE (6)
           lz4_valid_frame(p)              -> IH_COMP_LZ4    (5)  @0xaa83bc
           gzip_parse_header(p, 0xffff) >0 -> IH_COMP_GZIP   (1)
           lzma_check(p)                   -> IH_COMP_LZMA   (3)
           otherwise                       -> IH_COMP_NONE   (0)
```

`lz4_valid_frame` and `ulz4fn` accept only **frame** framing (`04 22 4d 18`) with
**independent blocks**; legacy `02 21 4c 18` is never tested for, and linked
blocks get `-EPROTONOSUPPORT`. The failing card was legacy-framed, so `sniff`
returned `IH_COMP_NONE` and U-Boot jumped into the LZ4 header as if it were an
`Image`. `lz4 -12 -BI --no-frame-crc` does boot — and is 0.17 s slower than gzip,
because 2.53 MiB more to read off the card costs more than the faster inflate
saves. The lz4 option was removed from the build in 2026-09 for that reason.

**zstd is not available** in this U-Boot: no zstd magic appears in the
disassembly in either byte order, and there are no zstd strings — 2017.09
predates `lib/zstd`.

### Why the inflate cost is what it is

Feeding the lz4 boot through the same padded-payload split gives a 0.285 s lz4
inflate, where desktop intuition says LZ4 should be ~10x faster than gzip, not
0.8x.

**Retracted (2026-08-24):** that "both inflaters are bounded by memory bandwidth".
Measured on hardware with DDR at its *lowest* rate: 1.9 GB/s, against inflates
running at 106 and 128 MB/s of output — 15–18x below the floor of the mechanism
blamed for them. What fits instead is **the CPU clock during U-Boot**: 106 MB/s
of gzip output is an A55 somewhere near 600 MHz–1 GHz, against parts that run to
1992 MHz, and cpufreq does not probe until ~1.2 s into the kernel. `cpu@0` carries
no `assigned-clock-rates` and no `rockchip,cpu-init-rate`, and armclk cannot be
raised without moving `vdd_cpu`, a ranged `tcs4525` rail U-Boot never programs —
so like the 10.9 MB/s read, this is real, large and unreachable from the device
tree.

### Compared with H700, 2026-08-23

Against [BaseOS for H700](https://github.com/pvaibhav/BaseOS) on an RG40XXV, at
the point where my355 reached hand-off in 4.98 s:

| | H700 (RG40XXV) | my355 (2026-08-23) |
|---|---|---|
| LED → frontend hand-off | **2.96 s** | 4.98 s |
| ├ bootloader + kernel + init | 2.04 s | 4.73 s |
| └ `rcS` + hand-off | 0.92 s | **0.25 s** |
| frontend init → first frame | 4.18 s | **2.95 s** |
| **LED → first frame** | **7.14 s** | 7.93 s |

The two ports landed within a second of each other by trading opposite strengths:
a ~4x leaner userland here against a bootloader-and-kernel phase 2.69 s slower.
Their port replaces the rootfs and nothing else, which works because the vendor
put the whole chain on the SD card *and* their inherited bootloader is already
fast — neither holds here. "Don't touch the bootloader" is a conclusion from
their numbers, not a principle inherited from them.
