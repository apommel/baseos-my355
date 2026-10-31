#!/bin/sh
# Sector 1 of miyoo355_fw.img: run by stock's miyoo_fw_update as root, cwd = the card.
# Its only job is to unpack the real installer, which starts at sector 16.
export MIYOO_FW=miyoo355_fw.img
echo 2 > /tmp/fwupdate_progress
rm -rf /tmp/baseos-install
mkdir -p /tmp/baseos-install
dd if=$MIYOO_FW bs=512 skip=16 count=256 2>/dev/null | tar x -C /tmp/baseos-install 2>/dev/null
if [ ! -f /tmp/baseos-install/install.sh ]; then
    echo 100 > /tmp/fwupdate_progress
    echo 1 > /tmp/fwupdate_done
    exit 1
fi
CARD="$(pwd)" sh /tmp/baseos-install/install.sh
