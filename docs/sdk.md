# The SDK

A cross-toolchain and a sysroot holding every library the rootfs ships, with
headers and pkg-config files, so a frontend builds against exactly what runs on
the device instead of a stock toolchain and bundled copies.

```sh
./build-rootfs.sh --sdk    # → work/my355/baseos-my355-sdk.tar.gz
```

It runs on **aarch64 Linux**, natively or in a `linux/arm64` container (as on
Apple Silicon): Buildroot builds the SDK's tools for the machine that built
them, and BaseOS builds in an arm64 container.

## Using it

```sh
tar -xzf baseos-my355-sdk.tar.gz && cd baseos-my355-sdk
./relocate-sdk.sh                  # once, after moving it anywhere
. ./environment-setup              # CC, CXX, PKG_CONFIG, CROSS_COMPILE, ...
```

- **Make or autotools**: `$CC`, `pkg-config --cflags --libs sdl3`, or
  `./configure $CONFIGURE_FLAGS`, as `environment-setup` prints.
- **CMake**: `cmake -DCMAKE_TOOLCHAIN_FILE=$PWD/share/buildroot/toolchainfile.cmake`.

GCC 15 and glibc 2.44: a program built here needs this rootfs, not stock's.
Build for stock (GLIBC 2.36 and older) with stock's toolchain.

## What to link

Everything in the sysroot is on the device, at the same soname: SDL3 and its
image, ttf and mixer add-ons, SDL2 (sdl2-compat), EGL and GLES (libmali, or Mesa
with `gpu=panfrost`), Vulkan, ALSA, libudev, D-Bus, curl and OpenSSL, sqlite,
libzip, libarchive, zstd, lz4, xz, bzip2, zlib, libpng, libjpeg, libwebp,
freetype, HarfBuzz, libsamplerate, cJSON and libevdev. The versions are in
`work/my355/rootfs.json`.

A frontend need not bundle any of these. If it bundles its own copy anyway,
the copy wins in the frontend's processes through `LD_LIBRARY_PATH`, and
rootfs programs keep theirs ([what frontends need](rootfs-interface.md)).

## On the device

For debugging over adb: `gdbserver` (`gdb-multiarch` on the host, with the
SDK's sysroot as `set sysroot`), `strace`, `evtest`, `iw`, `aplay`,
`speaker-test`, `sqlite3`, `zstd`, and BusyBox's `i2cdetect`, `i2cget`,
`i2cset` and `i2cdump`.
