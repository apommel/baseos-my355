# The SDK

A cross-toolchain and a sysroot holding every library the rootfs ships, with
headers and pkg-config files, so a frontend builds against exactly what runs on
the device instead of a stock toolchain and bundled copies.

```sh
./build.sh sdk    # → work/images/flipbase-my355-sdk.tar.gz
```

It runs on the Linux it was built on: **aarch64**, natively or in a
`linux/arm64` container (as on Apple Silicon), or **x86_64** with
`FLIPBASE_BUILD_PLATFORM=linux/amd64 ./build.sh sdk`. Buildroot builds the
SDK's tools for the machine that built them; they compile for aarch64 either
way. Each release has both, and the image below.

## The Docker image

The SDK ready to use, for x86_64 and arm64 hosts, with make, CMake and Ninja:

```sh
docker run --rm -v "$PWD":/src ghcr.io/apommel/flipbase-my355-sdk:2.0.0 make
docker run --rm -v "$PWD":/src ghcr.io/apommel/flipbase-my355-sdk:2.0.0 \
  sh -c 'cmake -B build -G Ninja && cmake --build build'
```

Tags follow releases (`2.0.0`, `2.0`, `latest`). Every bash in it has
`environment-setup` applied, so `$CC`, `pkg-config` and `CMAKE_TOOLCHAIN_FILE`
point at the SDK, also in a GitHub Actions job:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container: ghcr.io/apommel/flipbase-my355-sdk:2.0.0
    steps:
      - uses: actions/checkout@v7
      - run: cmake -B build -G Ninja && cmake --build build
```

The image is [sdk/Dockerfile](../sdk/Dockerfile) on top of the release's SDK.

## Using the tarball

```sh
tar -xzf flipbase-my355-sdk.tar.gz && cd flipbase-my355-sdk
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
freetype, HarfBuzz, libsamplerate, cJSON and libevdev, at Buildroot 2026.08.1's versions or `package/`'s.

A frontend need not bundle any of these. If it bundles its own copy anyway,
the copy wins in the frontend's processes through `LD_LIBRARY_PATH`, and
rootfs programs keep theirs ([what frontends need](rootfs-interface.md)).

## On the device

For debugging over adb: `gdbserver` (`gdb-multiarch` on the host, with the
SDK's sysroot as `set sysroot`), `strace`, `evtest`, `iw`, `aplay`,
`speaker-test`, `sqlite3`, `zstd`, and BusyBox's `i2cdetect`, `i2cget`,
`i2cset` and `i2cdump`.
