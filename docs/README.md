# BaseOS for the Miyoo Flip — how it works

Reference docs for the port: Rockchip RK3566, `MIYOO RK3566 355 V10 Board`,
NextUI platform id **`my355`**. For installing BaseOS, see
[INSTALL.md](../INSTALL.md); for building it, [CONTRIBUTING.md](../CONTRIBUTING.md).

Everything here was observed on hardware unless it says *inferred* (read out of a
binary and not confirmed by a boot). Claims that turned out to be wrong are kept,
not deleted, in [history](history.md).

## The pages

**Reference — how it works now**

| | |
|---|---|
| [hardware](hardware.md) | SoC, MTD layout, kernel config, SD slots. Start here. |
| [boot chain](boot-chain.md) | The preloader patch, the card installer, and how SD boot works at all. |
| [the card](card.md) | Partition layout, image build, boot image surgery, first-boot expansion, A/B updates. |
| [rootfs](rootfs.md) | The harvest, the overlay, init, adb, and what NextUI needs from the OS. |
| [boot time](boot-time.md) | Where the time goes, what each change was worth, what is left. |

**When something is wrong**

| | |
|---|---|
| [diagnostics](diagnostics.md) | Debugging a device that can print nothing. |
| [recovery](recovery.md) | Taking a NAND backup, restoring the preloader, getting back to stock. |

**Why it is the way it is**

| | |
|---|---|
| [decisions](decisions.md) | The choices the port rests on, and what is still open. |
| [U-Boot](uboot.md) | Tuning it (tried, 22 ms) and replacing it (shelved). |
| [history](history.md) | Experiments, SPL disassembly, superseded measurements, every retracted theory. |

## The short version

The stock preloader **cannot** boot this device from SD, and no card layout
changes that: its SPL device tree has an empty `/pinctrl` node, so the SD pins
are never muxed. A preloader with a working `/pinctrl` can, and it looks up a GPT
partition named `uboot` and reads a U-Boot FIT from its first sector.

So BaseOS patches **2 MiB of internal NAND** — the user's own preloader, in
place, from a card, with a backup written first — and leaves stock U-Boot, the
kernel and the stock rootfs untouched. Card in: BaseOS. Card out: stock, exactly
as before.

From there the card supplies the vendor U-Boot, the vendor kernel with a rewritten
command line, and a BusyBox userland built on a measured subset of the stock
libraries. Power-on to frontend hand-off is **3.73 s**, against stock's 15.79 s.
