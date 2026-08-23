# Parked: BaseOS for Allwinner H700

Nothing here is built, tested or shipped by this repository. It is the H700 port
as it stood at the fork point, kept for two reasons.

**Features not yet ported.** A/B updates (`overlay/usr/sbin/baseos-update`,
`tools/mkupdate.py`, `tools/gptslot.c`, `build-update.sh`), first-boot
expand-to-fill (`overlay/usr/sbin/expand-storage`, `tools/gptgrow.c`), USB mass
storage (`overlay/usr/sbin/usb-storage-mode`, `boot-menu-held`), the SSH dev
flavour (`overlay/etc/init.d/dev`, `build-tools.sh`, `tools/tools-stamp.sh`) and
the `tests/` suite. The Flip's GPT already reserves slot B at LBA 1163264, so the
update path is a port rather than a design.

**Prior art.** `docs/` here is cited thirteen times from the my355 docs.

It targets a different SoC, a different boot chain and a device profile system
(`devices.json`) with no meaning on this hardware. Prune it with
`git rm -r upstream-h700` whenever it stops earning its place.
