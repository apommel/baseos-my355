#!/bin/sh
# Buildroot's half of the rootfs: build-rootfs.sh adds init, BusyBox and
# overlay/, whose init scripts are the only ones that run.
set -eu
TARGET="$1"

rm -rf "$TARGET"/etc/init.d "$TARGET"/usr/share/man "$TARGET"/usr/share/doc \
       "$TARGET"/usr/share/licenses "$TARGET"/usr/share/zoneinfo/right
