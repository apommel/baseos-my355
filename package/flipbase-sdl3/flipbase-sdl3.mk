################################################################################
#
# flipbase-sdl3
#
################################################################################

FLIPBASE_SDL3_VERSION = 3.4.20
FLIPBASE_SDL3_SOURCE = SDL3-$(FLIPBASE_SDL3_VERSION).tar.gz
FLIPBASE_SDL3_SITE = http://www.libsdl.org/release
FLIPBASE_SDL3_DL_SUBDIR = sdl3
FLIPBASE_SDL3_LICENSE = Zlib
FLIPBASE_SDL3_LICENSE_FILES = LICENSE.txt
FLIPBASE_SDL3_INSTALL_STAGING = YES
FLIPBASE_SDL3_DEPENDENCIES = alsa-lib dbus libdrm libegl libgbm libgles libudev

# All listed, so a library that happens to be in staging adds no backend.
FLIPBASE_SDL3_CONF_OPTS = \
	-DSDL_TESTS=OFF \
	-DSDL_EXAMPLES=OFF \
	-DSDL_INSTALL_DOCS=OFF \
	-DSDL_RPATH=OFF \
	-DSDL_UNIX_CONSOLE_BUILD=ON \
	-DSDL_KMSDRM=ON \
	-DSDL_OPENGLES=ON \
	-DSDL_OPENGL=OFF \
	-DSDL_VULKAN=ON \
	-DSDL_X11=OFF \
	-DSDL_WAYLAND=OFF \
	-DSDL_VIVANTE=OFF \
	-DSDL_ALSA=ON \
	-DSDL_PULSEAUDIO=OFF \
	-DSDL_PIPEWIRE=OFF \
	-DSDL_JACK=OFF \
	-DSDL_SNDIO=OFF \
	-DSDL_LIBUDEV=ON \
	-DSDL_DBUS=ON \
	-DSDL_IBUS=OFF \
	-DSDL_HIDAPI=ON \
	-DSDL_HIDAPI_LIBUSB=OFF \
	-DSDL_LIBURING=OFF

$(eval $(cmake-package))
