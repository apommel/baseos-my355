#!/bin/sh
# Trims the target, adds the assets and version, and checks every program
# finds its libraries.
set -eu
T="$1"
ASSETS="$BR2_EXTERNAL_FLIPBASE_PATH/board/my355/assets"
PATCHELF="$HOST_DIR/bin/patchelf"

rm -rf "$T"/usr/share/man "$T"/usr/share/doc "$T"/usr/share/licenses \
       "$T"/usr/share/zoneinfo/right "$T"/usr/share/vulkan/registry
# HarfBuzz's extras and gdbserver's tracepoints: SDL3_ttf needs only libharfbuzz.
rm -f "$T"/usr/bin/hb-* "$T"/usr/lib/libharfbuzz-*.so* "$T"/usr/lib/libinproctrace.so

# bt_init.sh insmods this path: the stand-in that loads mainline btusb.
ln -sf "$(cd "$T"/usr/lib/modules && echo */kernel/drivers/bluetooth/rtk_btusb.ko)" \
    "$T"/usr/lib/modules/rtk_btusb.ko

install -D -m 0644 -t "$T"/usr/share/flipbase \
    "$ASSETS"/boot.ttf "$ASSETS"/card-readme.txt "$ASSETS"/flipbase.conf

# All from VERSION, so they cannot drift. NextUI's About screen reads
# /usr/miyoo/version.
printf 'FLIPBASE_VERSION=%s\nFLIPBASE_BUILD=%s\n' "$FLIPBASE_VERSION" "$FLIPBASE_BUILD" \
    >> "$T"/etc/flipbase-release
cat > "$T"/usr/lib/os-release <<EOF
NAME="FlipBase"
ID=flipbase
VERSION_ID=$FLIPBASE_VERSION
PRETTY_NAME="FlipBase $FLIPBASE_VERSION (my355)"
HOME_URL="https://github.com/apommel/FlipBase"
EOF
mkdir -p "$T"/usr/miyoo
echo "FlipBase $FLIPBASE_VERSION" > "$T"/usr/miyoo/version

# libmali's names that Mesa stands in for link through $GPU, which flipbase-gpu
# sets: an overlay on /usr hides bind mounts. Redone as each build restores them.
GPU=/run/flipbase/gpu
(
    cd "$T"/usr/lib
    mkdir -p mali/vulkan
    # file:name, as a soname may be a link to the file.
    for pair in libEGL.so.1:libEGL.so.1 libGLESv1_CM.so.1:libGLESv1_CM.so.1 \
        libGLESv2.so.2:libGLESv2.so.2 libgbm.so.1:libgbm.so.1 \
        "$(readlink libmali.so.1):libmali.so.1" \
        "$(readlink libmali-hook.so.1):libmali_hook.so.1"; do
        f=${pair%:*} name=${pair#*:}
        [ -L "$f" ] && continue
        mv -f "$f" mali/
        [ "$f" = "$name" ] || ln -sfn "$f" mali/"$name"
        ln -s "$GPU/$name" "$f"
    done
    if [ ! -L ../share/vulkan/icd.d ]; then
        rm -rf mali/vulkan/icd.d
        mv ../share/vulkan/icd.d mali/vulkan/
        ln -s "$GPU"/vulkan/icd.d ../share/vulkan/icd.d
    fi
)

# Whether $1 resolves through $GPU, to a name both stacks have.
gpu_link_ok() {
    p=$1
    while [ -L "$p" ]; do
        t=$(readlink "$p")
        case "$t" in
            "$GPU"/*)
                [ -e "$T/usr/lib/mali/${t#"$GPU"/}" ] && [ -e "$T/usr/lib/mesa/${t#"$GPU"/}" ]
                return ;;
            /*) p=$T$t ;;
            *) p=${p%/*}/$t ;;
        esac
    done
    return 1
}

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
            if [ -e "$T$d/$n" ] || gpu_link_ok "$T$d/$n"; then continue 2; fi
        done
        echo "${f#"$T"} needs $n"
    done
done > "$BUILD_DIR"/unresolved
if [ -s "$BUILD_DIR"/unresolved ]; then
    echo "unresolved libraries:" >&2
    cat "$BUILD_DIR"/unresolved >&2
    exit 1
fi
