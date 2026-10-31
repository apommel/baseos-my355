#!/bin/sh
# Trims the target, adds the assets and version, and checks every program
# finds its libraries.
set -eu
T="$1"
ASSETS="$BR2_EXTERNAL_BASEOS_PATH/board/my355/assets"
PATCHELF="$HOST_DIR/bin/patchelf"

rm -rf "$T"/usr/share/man "$T"/usr/share/doc "$T"/usr/share/licenses \
       "$T"/usr/share/zoneinfo/right "$T"/usr/share/vulkan/registry
# HarfBuzz's extras and gdbserver's tracepoints: SDL3_ttf needs only libharfbuzz.
rm -f "$T"/usr/bin/hb-* "$T"/usr/lib/libharfbuzz-*.so* "$T"/usr/lib/libinproctrace.so

# bt_init.sh insmods this path: the stand-in that loads mainline btusb.
ln -sf "$(cd "$T"/usr/lib/modules && echo */kernel/drivers/bluetooth/rtk_btusb.ko)" \
    "$T"/usr/lib/modules/rtk_btusb.ko

install -D -m 0644 -t "$T"/usr/share/baseos \
    "$ASSETS"/boot.ttf "$ASSETS"/card-readme.txt "$ASSETS"/baseos.conf

# All from VERSION, so they cannot drift. NextUI's About screen reads
# /usr/miyoo/version.
printf 'BASEOS_VERSION=%s\nBASEOS_BUILD=%s\n' "$BASEOS_VERSION" "$BASEOS_BUILD" \
    >> "$T"/etc/baseos-release
cat > "$T"/usr/lib/os-release <<EOF
NAME="BaseOS"
ID=baseos
VERSION_ID=$BASEOS_VERSION
PRETTY_NAME="BaseOS $BASEOS_VERSION (my355)"
HOME_URL="https://github.com/apommel/baseos-my355"
EOF
mkdir -p "$T"/usr/miyoo
echo "BaseOS $BASEOS_VERSION" > "$T"/usr/miyoo/version

# Frontends put their own libcrypto, libzstd, ... first in LD_LIBRARY_PATH:
# DT_RPATH, unlike DT_RUNPATH, is searched before it. Mesa keeps its own.
find "$T"/usr -type f ! -name "*.ko" | while read -r f; do
    needed=$("$PATCHELF" --print-needed "$f" 2>/dev/null) || continue
    [ -n "$needed" ] || continue
    case "$f" in
        "$T"/usr/lib/mesa/*) ;;
        *) "$PATCHELF" --force-rpath --set-rpath /usr/lib "$f" ;;
    esac
    dir=${f%/*}
    rpath=$("$PATCHELF" --print-rpath "$f" | sed "s|\$ORIGIN|${dir#"$T"}|g" | tr : " ")
    for n in $needed; do
        for d in /usr/lib $rpath; do
            if [ -e "$T$d/$n" ]; then continue 2; fi
        done
        echo "${f#"$T"} needs $n"
    done
done > "$BUILD_DIR"/unresolved
if [ -s "$BUILD_DIR"/unresolved ]; then
    echo "unresolved libraries:" >&2
    cat "$BUILD_DIR"/unresolved >&2
    exit 1
fi
