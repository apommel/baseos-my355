# Parked: BaseOS for Allwinner H700

Nothing in this directory is built, tested or shipped by this repository. It is the
H700 port as it stood at the fork point, kept intact for two reasons:

1. **Features not yet ported.** A/B system updates (`overlay/usr/sbin/baseos-update`,
   `tools/mkupdate.py`, `tools/gptslot.c`, `build-update.sh`), first-boot
   expand-to-fill (`overlay/usr/sbin/expand-storage`, `tools/gptgrow.c`), USB mass
   storage mode (`overlay/usr/sbin/usb-storage-mode`, `boot-menu-held`), the SSH/SFTP
   dev flavour (`overlay/etc/init.d/dev`, `build-tools.sh`, `tools/tools-stamp.sh`)
   and the test suite under `tests/`. The Flip's GPT already reserves a slot B at LBA
   1163264, so the update path is a port rather than a design.

2. **Prior art.** `docs/` here is cited thirteen times from the my355 docs — the boot
   budget comparison, the OTG lessons, the partition/update design.

Read it as reference, not as code you can run: it targets a different SoC, a
different boot chain and a device profile system (`devices.json`) that has no meaning
on this hardware.

Prune it with `git rm -r upstream-h700` whenever it stops earning its place; the
history keeps it either way.
