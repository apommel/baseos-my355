# BaseOS Install Guide (Miyoo Flip)

BaseOS boots your Miyoo Flip from the SD card and hands off to NextUI. It does not
replace the stock system. Take the card out and the Flip boots stock again, exactly as
before.

Installing does make one change to internal storage: a 2 MiB patch to the preloader, so
the device will look at the SD card when it starts. The card does this for you on the
first boot. Nothing else in internal storage is touched, and your own preloader is
backed up to the card before anything is written.

## Before you start

BaseOS for the Flip is a work in progress, and installing it writes to the device's
internal storage. That carries real risk.

The change is small and deliberately conservative. It touches 2 MiB, the preloader
only, and leaves the stock system, its kernel and its bootloader alone. The installer
copies your original preloader to the SD card before it erases anything, checks what it
wrote afterwards, and puts the original back if it cannot verify the result. It has
been tested on hardware from start to finish.

None of that makes it risk-free. It has been tested on very few devices and very few
firmware versions, yours may differ in ways we have not seen, and a power loss at the
wrong moment can still leave the device needing recovery over USB.

Install at your own risk. Back up anything on your SD cards that you care about first,
and read the last section of this page before you begin, so you know what recovery
looks like if you need it.

## What you need

- A Miyoo Flip
- An SD card of 4GB or larger for BaseOS
- A computer with an SD card reader
- Raspberry Pi Imager, balenaEtcher, [Flash Tool](https://github.com/pvaibhav/FlashTool/)
for Mac users, or any tool that writes a disk image
- A second SD card with NextUI on it (see below)
- At least 25% battery, or the Flip on its charger

## How to install BaseOS?

1. Download **baseos-my355-\<version\>.img.zip** from the releases page.
2. Use Raspberry Pi Imager to burn the image to an empty SD card. Choose
   **Use Custom** and select the .zip file; there is no need to unzip it first.
3. Put the card in the **right-hand SD slot**. This is the only slot the Flip can boot
   from.
4. Power the Flip on.

The stock system will start as usual, and after a few seconds a **firmware update**
progress bar will appear. This is the preloader patch. Please be patient and do not
power the device off while it runs. It takes about four seconds.

The Flip will then reboot by itself and come up in BaseOS. On that first boot it
takes a second to expand the card's BASEOS volume to the full size of the card, and
shows **EXPANDING STORAGE** while it does. Anything already on the volume is kept.

This only happens once. From then on the Flip boots straight to BaseOS whenever the
card is in the right-hand slot, and boots stock whenever it is not.

The installer leaves two files on the card's BASEOS volume, which you can read from
your computer:

- **baseos-preloader.log**, a record of what was done
- **mtd5-original-\<hash\>.img**, a copy of your own original preloader

Keep the second one. It is the way back if you ever want to undo the change.

If your Flip already runs GammaLoader, nothing will happen at all. BaseOS will simply
boot from the card, and your existing preloader is left alone.

## How to install NextUI?

BaseOS needs a frontend. Put NextUI on a **second SD card** and insert it in the
**left-hand slot**. BaseOS will find it and start it automatically.

If you already use NextUI on your Flip, use that exact card. Move it from the
right-hand slot to the left-hand slot and you are done. Your settings, saves and ROMs
all carry over untouched, and nothing needs to be reinstalled.

A brand-new card works too: format it FAT32, unzip a NextUI `base` (or `all`) release
onto it, and put it in the left-hand slot. BaseOS installs it on the next boot, NextUI's
own progress screen and all. It does not need to have been started on stock first.

You're done, enjoy!

### Advanced: one card for both

BaseOS and NextUI can share one card, leaving the left-hand slot free. Two cards is
still the recommended setup: your games and saves stay on a card you can pull out,
reformat or replace without touching the one that boots the device.

**After** the first boot — the volume is only 64 MB until then — put the card in your
computer and unzip a NextUI `base` (or `all`) release onto the BASEOS volume, next to
`README.txt`. Put the card back in the right-hand slot and power on; NextUI installs
itself as it would on any other card.

A card carrying a frontend in the left-hand slot is still used in preference, so an
occasional second card works, and an empty one changes nothing.

## How to update BaseOS?

To update BaseOS, you can simply re-flash the SD card. If you are using a one-card
setup and do not want to overwrite your front-end data, the `.bosupd` file can be
used to update only the OS without re-flashing the card.

Download `baseos-my355-<version>.bosupd` and copy it to the root of either card,
then power on. The screen shows **UPDATING SYSTEM** with a progress bar for about a
minute and the Flip reboots into the new version.

Your ROMs, saves and settings are untouched: the card reserves spare space for this,
and the update writes there rather than over the volume your files are on. If the new
version does not start, the Flip restores the previous one by itself after three
tries.

You can leave the file on the card — it is applied once and then ignored.

## If something goes wrong

Most problems are bounded by design. The stock system, its kernel and its bootloader
are never touched, so in the common failure the Flip simply comes back to stock and you
try again. The preloader is only rewritten after the patched copy has been checked, and
if the write cannot be verified the installer puts your original back by itself.

The cases below are the ones that have actually been seen. This is new software on a
device with more than one firmware version in circulation, so you may hit something
that is not on this list. If you do, power off, take the card out, and start the Flip
without it — if stock comes up, nothing is lost and you can try again. Keep
**baseos-preloader.log** and the **mtd5-original** file from the card; between them
they say what happened and hold the way back.

### The Flip boots to stock and no update bar appears

The card was not found. Power off, check that the card is in the right-hand slot, and
try again. If it still does nothing, write the image to the card again, and try a
different SD card if you have one.

### The update ran, but the Flip came back to stock

Read **baseos-preloader.log** on the card's BASEOS volume from your computer.

- If it says **move the card to the right-hand slot**, the card was in the left-hand
  slot. The patch worked. Move the card over and power on.
- If it says **not patched**, nothing was written, because the preloader was already
  patched or is GammaLoader's. In that case check that you wrote a full BaseOS image to
  the card rather than only copying files onto it.

### BaseOS shows INSERT SD CARD, or ADD FRONTEND TO SD CARD

BaseOS is running and has no frontend to hand off to. The first message means the
left-hand slot is empty, the second that the card in it carries no frontend. Put
NextUI on a card in the left-hand slot, as above.

### You copied a .bosupd and nothing happened

Updates are skipped in silence, because the check runs on every boot. To see why, run
`baseos-update status` over adb: it lists every payload it can find with the verdict
for each — most often the file is older than what is already installed, or it has been
applied before.

### The Flip does not start at all

Rare, and realistically only if power was lost during the write. Put the Flip on its
charger and try again first, with the SD card removed.

If the screen stays dark and the device does nothing, the preloader did not survive.
The Flip is not permanently broken: it can be restored over USB with RKDevTool, using
the [Miyoo Flip unbricking guide](https://github.com/spruceUI/spruceOS/wiki/16.-Miyoo-Flip-Unbricking).
That restores the device to stock firmware, after which you can install again.

### You want to go back to stock

Take the card out. The Flip boots stock, with everything as it was.

To undo the preloader patch as well, write the **mtd5-original-\<hash\>.img** file from
your card back to internal storage. See
[docs/03-nand-backup-and-recovery.md](docs/03-nand-backup-and-recovery.md).
