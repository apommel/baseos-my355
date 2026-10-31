#!/bin/sh
# Runs on the image's copy of the target, after makedevs and mkusers have
# set up the files these links replace.
set -eu
T="$1"

# The root is read-only: what changes lives in /run or /data. baseos-config
# writes shadow, hostname and hosts from baseos.conf, starting from this shadow;
# rcS restores machine-id; the udhcpc script writes resolv.conf.
mkdir -p "$T"/usr/share/baseos
mv "$T"/etc/shadow "$T"/usr/share/baseos/shadow
chmod 600 "$T"/usr/share/baseos/shadow
for f in shadow hostname hosts machine-id resolv.conf; do
    rm -f "$T"/etc/$f
    ln -s /run/$f "$T"/etc/$f
done
# root's shell history and SSH keys; /etc/init.d/dev creates it.
rm -rf "$T"/root
ln -s /data/root "$T"/root
# As stock: NextUI copies the chosen zone there, and the frontend bind-mounts
# its card copy on /userdata.
rm -f "$T"/etc/timezone
ln -sf /userdata/localtime "$T"/etc/localtime

# Stock uses the lowercase path, NextUI the uppercase one.
mkdir -p "$T"/data "$T"/userdata "$T"/mnt/SDCARD
ln -sfn /mnt/SDCARD "$T"/mnt/sdcard

if [ "$BASEOS_DIAG" = 1 ]; then cp -a "$BR2_EXTERNAL_BASEOS_PATH"/../overlay-diag/. "$T"/; fi
