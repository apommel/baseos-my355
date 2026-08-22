# my355 · SD boot — how it works

How this device boots from an SD card when one is present and falls back to the stock
OS when it is not.

> **Provenance.** Measured on hardware over adb, 2026-08-19 to 2026-08-22. Claims are
> *verified* (observed on hardware) or *inferred* (from binaries); retracted ones are
> kept in the [investigation log](05-investigation-log.md).

Two pieces are required, and only the first involves internal flash:

1. a preloader in `mtd5` whose SPL device tree has a working `/pinctrl`, and
2. a GPT partition named **`uboot` at sector 16384** on the card.

Since 2026-08-22 the preloader is **this unit's own, patched** — previously it was
GammaLoader's. Nothing else in NAND is touched: `mtd1` (U-Boot + BL31), `mtd2`
(kernel) and `mtd3` (rootfs) stay stock.

---

## The preloader

### What was wrong with the stock one

**Its `/pinctrl` node has zero properties** — not `status = "disabled"`, an empty
skeleton. No `compatible` → no pinctrl driver binds → `dwmmc@fe2b0000`'s `pinctrl-0`
(`sdmmc0-clk/cmd/bus4/det`) is never applied → the SD pins stay in their reset
function and `mmc_init()` fails before a sector is read. SPI-NAND is unaffected
because the bootrom already muxed the SFC pins to fetch the preloader.

It is the fingerprint of `fdtgrep`, which keeps tagged nodes and leaves untagged
*ancestors* as empty skeletons. Miyoo tag everything around the node but not the node:

| node | `u-boot,dm-spl` in Miyoo's tree? |
|---|---|
| `/pinctrl` | **no** — hence the skeleton |
| `/pinctrl/gpio@fdd60000` (and the other two banks) | yes |
| `/pinctrl/sdmmc0_pins/*` | yes |
| `/syscon@fdc60000`, `/dwmmc@fe2b0000` | yes |

Two further confirmations: the node's own children still reference
`gpio-ranges = <0x100000dd …>`, a phandle that appears nowhere in the tree and sits in
a hole between `0x100000dc` (PMUGRF) and `0x100000de` — the value stripped off
`/pinctrl`; and the driver is linked in, `rockchip_rk3568_pinctrl` and its of_match
string sitting together in SPL rodata at `0x5f545` beside the pinconf parameter table.

Since Miyoo tag the pin groups, tag the gpio banks, keep `pinctrl-0` on the SD
controller *and* list both SD slots ahead of NAND in the boot order, SD boot was
plainly intended. The untagged parent is an oversight.

It also explains the absent GPIO: with `/pinctrl` unbound its children never bind
either. And it settles that the old "the SPL cannot power the slot" theory was wrong —
the rail is on by default at reset. The problem was pin mux, which no card layout can
fix.

### The patch

Restore the nine properties Rockchip's own loaders carry on that node, and nothing
else. Both syscons are already present with the exact phandles they reference, both
already `u-boot,dm-spl` and `okay`:

```
compatible = "rockchip,rk3568-pinctrl";  rockchip,grf = <0x1000001b>;
rockchip,pmu = <0x100000dc>;             #address-cells = <2>;
#size-cells = <2>;                       ranges;
u-boot,dm-spl;                           status = "okay";
phandle = <0x100000dd>;
```

**+180 bytes into 649 bytes of zero slack** between the device tree's end and the SPL
image's end, so the declared image size, the sector counts and the load footprint are
all unchanged. Afterwards the whole SD path — `dwmmc@fe2b0000`, the four `sdmmc0` pin
groups, both syscons, `/pinctrl` — is byte-identical to GammaLoader's, bar the marker
spelling (ours uses `u-boot,dm-spl`, what stock's own bound nodes use).

`tools/mkpreloader_my355.py` builds it from a dump and re-checks every invariant,
refusing to write if any fails.

### The container

Two identical IDB (`RKNS`) copies at `0x20000` and `0x80000` (pages 64 and 256,
2048-byte pages). Each holds a 2-entry table at `+0x78`, stride `0x58`: `u16` sector
offset, `u16` sector count, then a **plain SHA-256 at `+0x18` over exactly those
bytes**. Entry 1 is the DDR blob, entry 2 the SPL.

| | entry 1 (DDR) | entry 2 (SPL) |
|---|---|---|
| stock | sectors 4–111, 55 296 B | sectors 112–591, 245 760 B |

There is no RSA signature, and loaders with entirely different hashes boot on this
unit, so the bootrom accepts any correctly-hashed IDB. Block 0 additionally holds a
**GPT for the whole SPI NAND** (`EFI PART` at sector 1) listing
`vnvm`/`uboot`/`boot`/`rootfs`/`userdata` at the offsets `/proc/mtd` reports.

### Why the failure modes are bounded

- The **SPL code is byte-identical** (239 064 bytes before the tree); only device tree
  properties are added.
- The **DDR blob is byte-identical**, which is the point: the unit keeps its own V1.18.
- **`dwmmc@fe2b0000` is the only node in the tree with `pinctrl-0`**, so binding
  pinctrl cannot perturb the SPI-NAND path.
- If the driver fails to bind, or binds and mis-muxes, the SD read fails and the SPL
  walks on to `sfc/flash@0` — today's behaviour.
- The patch takes the SPL from 15 to 19 bound devices, on silicon that runs 38 under
  Rockchip's own loader.

### Installed — 2026-08-22

Written from the running stock OS over adb. Battery 99% on USB power, `mtd5`
`flags 0x400`, **0 bad blocks**; `flash_erase` and `nandwrite` both `rc=0`; readback
byte-exact (md5 `ccc279738fa0123e914e15caca36412c`), 0 ECC failures, 0 corrected bits.
Verified again by pulling `/dev/mtd5ro` back and re-running the tool against it.

Result on hardware — **all three cases correct**:

| card | result |
|---|---|
| none | stock → MainUI |
| BaseOS card with a `uboot` partition | **boots BaseOS from SD**, `storagemedia=sd`, `root=/dev/mmcblk1p3` |
| card without one | falls through to stock |

Pre-kernel **3.114 s**, against 3.118 s under GammaLoader — no cost either way; boot
time was never the aim. DDR DVFS is healthy on the restored V1.18: all four FSPs
(324/528/780/1056 MHz), `dmc_ondemand`, ATF version `0x102`, and **no
`loader&trust unmatch`**, so the V1.18 ↔ BL31 pairing is fine.

### Procedure

`mtd5` is 2 MiB, 16 erase blocks of 128 KiB, `writesize` 2048, and
`flash_erase`/`nandwrite`/`nanddump` are all in the stock rootfs. Generate from **this
unit's own dump**, never a redistributed binary:

```sh
python3 tools/mkpreloader_my355.py mtd5-spl.img baseos-preloader.img
```

Stage the image *and both rollbacks* in `/tmp` (tmpfs, RAM) before erasing, so recovery
never needs a host transfer, and check their md5 on the device. Then:

```sh
flash_erase /dev/mtd5 0 0 && nandwrite -p /dev/mtd5 /tmp/baseos-preloader.img
md5sum /dev/mtd5ro          # must equal the generated image — check BEFORE rebooting
```

While the device is still booted the write can be repeated indefinitely, so the only
real hazard is power loss between the erase and a verified write.

### Recovery

1. **Device still boots** (the expected failure: SD ignored, stock comes up) — rewrite
   `mtd5-spl.img`. This is the case the design guarantees.
2. **Bootrom rejects the IDB** — it finds no valid preloader and enters USB **MASKROM**,
   recoverable with RKDevTool. Not a brick.
3. **Valid IDB that hangs** — needs MASKROM forced.

Cases 2 and 3 both end at `unbrick/MiniLoaderAll.bin` + `unbrick/update.img`, a
complete RKDevTool recovery for this device that **has already been performed on this
unit**. Note it is a Dec 2024 full image, so the later firmware must be reapplied
afterwards. Keep `mtd5-spl.img` (md5 `de535483…`) and `gammaloader-preloader.img`
(md5 `2252285d…`) to hand — [backup & recovery](03-nand-backup-and-recovery.md).

### Distribution — not done, but the route is clear

Stock's own firmware-update mechanism is a **root shell script runner**, which makes a
card-only installer possible. `/usr/miyoo/bin/runmiyoo.sh` looks for
`miyoo355_fw.img` on `/media/sdcard0` or `sdcard1`, compares the `version:` line in
its 512-byte text header against `/usr/miyoo/version`, and on a mismatch runs
`/usr/miyoo/apps/fw_update/miyoo_fw_update`, which does exactly:

```sh
dd if=miyoo355_fw.img of=/tmp/miyoo_fw_version.txt bs=128 count=1
dd if=miyoo355_fw.img of=/tmp/miyoo_update.sh bs=512 skip=1 count=8
chmod 777 /tmp/miyoo_update.sh
/tmp/miyoo_update.sh &
```

So the image layout is: header at 0, **an arbitrary 4 KiB root shell script at sector
1**, then whatever payloads that script wants (Miyoo's own uses 1 MiB `uboot.img`,
8 MiB `boot.img`, 80 MiB `rootfs.img`, and writes `mtd1`/`mtd2`/`mtd3` with
`flash_erase` + `dd`). Nothing stops such a script writing `mtd5`.

It runs in **userspace**, late — stock preloader → stock U-Boot → stock kernel →
`runmiyoo.sh` — so it is the same layer GammaOS and ROCKNIX use a stock App for, just
triggered automatically instead of by the user.

The shape that would work:

- The installer ships **no preloader binary**. The script `nanddump`s the unit's own
  `mtd5`, applies the 180-byte patch and rewrites it — so nothing of Miyoo's is
  redistributed, and units with a different SPL build (Nov 02 and Dec 12 2024 both
  exist in the wild) are handled correctly rather than being overwritten with a
  foreign loader.
- Everything needed is already in the stock rootfs: `nanddump`, `nandwrite`,
  `flash_erase`, `dd`, `sha256sum`, `xxd -r -p`, `cmp`. No Python, but the patch is
  byte splicing plus one SHA-256, so BusyBox shell suffices. The distributable is
  header + script, on the order of 4.5 KiB.
- It **self-terminates**: once the new preloader is in, the card's `uboot` partition
  wins and stock never runs again, so the image is never read a second time. But
  `/usr/miyoo/version` is not touched, so the version gate keeps matching — the script
  must be idempotent and exit if `/pinctrl` already has a `compatible`.
- Non-negotiable for unattended use: back the original `mtd5` up **to the card** first;
  verify all four IDB SHA-256s before touching anything; refuse on any unrecognised
  layout; check battery level; verify the readback before rebooting; and log to the
  card either way.

---

## Provenance — what GammaLoader is

GammaLoader's author describes it as flipping the boot priority of the stock preloader,
obtained by flashing over `rkdevtool` and dumping the first blocks of the SPI. The
outcome he describes is right — no custom U-Boot, stock U-Boot from internal flash, a
custom one on the card as ROCKNIX does — but the mechanism is not what happened.

**What he dumped is not a Miyoo preloader.** `rkdevtool`'s download-boot step sends its
own `MiniLoaderAll.bin`. Its device tree is Rockchip's untrimmed RK3568 EVB tree,
carrying `ethernet@fe010000`, `pcie@fe280000`, USB PHYs and a watchdog, none of which
this device has.

**And there was no boot priority to flip.** Five samples, four builds, two units — a
clean 2×2, every Miyoo build empty, every Rockchip generic one complete:

| loader | how it got there | SPL build | DDR blob | `/pinctrl` | tree |
|---|---|---|---|---|---|
| this unit's `mtd5` (before) | the unbrick `update.img` | Dec 12 2024 | V1.18, `rk3566_ddr_1056MHz` | **empty** | Miyoo, 202 props |
| RE repo `preloader.img` | factory, another unit | Nov 02 2024 | V1.18 | **empty** | Miyoo, 203 props |
| Nov 19 2024 SPI dump | factory, that same unit | Nov 02 2024 | V1.18 | **empty** | Miyoo, 203 props |
| `MiniLoaderAll.bin` | Rockchip SDK; drives the flash only | Dec 03 2021 | V1.16, `rk3566_ddr_780MHz` | complete | EVB, 487 props |
| GammaLoader | Rockchip SDK, left behind by `rkdevtool` | Apr 13 2021 | V1.10 | complete | EVB, 483 props |

Every Miyoo build already lists an SD slot ahead of SPI NAND — the Nov 2024 build has
*exactly* GammaLoader's boot order and still cannot read a card. The two `rkdevtool`
flows explain the disagreement entirely:

- **Upgrade Firmware with an `update.img`** (the unbrick route) writes *that package's*
  loader — Miyoo's — and SD boot stays broken.
- **Download Image with a `MiniLoaderAll.bin`** (Gamma's route) leaves *Rockchip's*
  loader in NAND, and SD boot starts working.

**This unit's `mtd5` came from the unbrick package, proven.** `unbrick/update.img` is
an `RKFW` stamped 2024-12-12 10:18:07 whose loader is stamped 10:17. Its DDR blob is
plaintext and its SPL XOR-scrambled with a fixed 512-byte repeating keystream;
recovering that keystream from the known DDR plaintext and applying it to `FlashBoot`
gives a byte-identical match (sha256 `3476f471…`) with the on-device SPL,
`U-Boot SPL 2017.09 (Dec 12 2024 - 10:17:54)`. That is also why its boot order differs
from the factory samples.

**Firmware version is not the variable.** Neither `miyoo355_fw.img` — official 20250527
nor the 20250627 given to developers — contains a preloader at all: no `RKNS`, no DDR
blob, no `U-Boot SPL`. They begin at the `uboot` partition, so an update never touches
`mtd5`.

---

## The card side

### The `uboot` partition

Create a GPT partition named **`uboot` starting at sector 16384**. For BaseOS it holds
the vendor U-Boot FIT; for ROCKNIX **no data need be written into it** — `u-boot.itb`
is already at that sector and the entry merely gives `part_get_info_by_name` something
to find.

That trick was necessary under GammaLoader, whose SPL diverges from stock's at exactly
one point in `spl_mmc.c`:

```
GammaLoader (Apr 2021)                     Stock (Dec 2024)
0x3250c  part_get_info_by_name("uboot")    0x3160c  part_get_info_by_name("uboot")
0x32520  mov w19, #-0x26   (-ENOSYS)       0x31628  mov x2, #0x4000
0x32524  b   -> RETURN FAILURE             0x31630  bl  -> load raw sector 0x4000
```

GammaLoader has **no raw-sector fallback**, so without the named partition it returns
`-38` and never looks at sector `0x4000`, which is where ROCKNIX places `u-boot.itb`.
**The patched stock preloader keeps that fallback**, so a ROCKNIX card should boot with
or without the partition — *inferred, not retested since the swap*.

### Card recipe

| | |
|---|---|
| `uboot` GPT partition | starts at sector **16384**; contents may be pre-existing |
| U-Boot FIT | at that sector — ROCKNIX's mainline `u-boot.itb` works; OP-TEE is **not** required |
| OS | whatever that U-Boot boots — ROCKNIX uses `/extlinux/extlinux.conf` on partition 1 |

Keep any added partitions below LBA 32768.

### Gotcha: ROCKNIX's storage resize runs exactly once

ROCKNIX expands `STORAGE` to fill the card on **first boot only**, then writes
`.configured`. A partition sitting immediately behind `storage` leaves the expansion
nowhere to go: `STORAGE` stays at 32 MiB, the config tree fills it to 100%,
EmulationStation cannot write `es_settings.cfg` and the UI never appears. Removing the
blocking partition afterwards does not help — the resize never retries. Re-flash and
re-add only the `uboot` partition at 16384–32767, which sits *before* partition 1.

---

**my355 docs:** [index](README.md) · [device & boot chain](00-device-and-boot-chain.md) · [boot budget](01-boot-budget.md) · [SD boot](02-sd-boot.md) · [backup & recovery](03-nand-backup-and-recovery.md) · [port plan](04-port-plan.md) · [investigation log](05-investigation-log.md) · [card image](06-card-image-build.md) · [bring-up](07-bringup-and-diagnostics.md) · [rootfs](08-rootfs.md) · [U-Boot](09-uboot.md)
