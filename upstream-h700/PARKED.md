# Parked: BaseOS for Allwinner H700

Nothing here is built, tested or shipped by this repository. It is the H700 port
as it stood at the fork point, kept for two reasons.

**Features not yet ported.** USB mass storage (`overlay/usr/sbin/usb-storage-mode`,
`boot-menu-held`), the SSH dev flavour (`overlay/etc/init.d/dev`, `build-tools.sh`,
`tools/tools-stamp.sh`) and most of the `tests/` suite.

First-boot expand-to-fill and A/B updates are ported. The Flip reserves a spare half
for `uboot` and `boot` as well as `rootfs`, because unlike here its boot image is
BaseOS-authored, so an update has to be able to replace it.

**Prior art.** `docs/` here is cited thirteen times from the my355 docs.

It targets a different SoC, a different boot chain and a device profile system
(`devices.json`) with no meaning on this hardware. Prune it with
`git rm -r upstream-h700` whenever it stops earning its place.
