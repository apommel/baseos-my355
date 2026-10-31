################################################################################
#
# sdl2-compat
#
################################################################################

SDL2_COMPAT_VERSION = 2.32.74
SDL2_COMPAT_SITE = https://github.com/libsdl-org/sdl2-compat/releases/download/release-$(SDL2_COMPAT_VERSION)
SDL2_COMPAT_LICENSE = Zlib
SDL2_COMPAT_LICENSE_FILES = LICENSE.txt
SDL2_COMPAT_INSTALL_STAGING = YES
SDL2_COMPAT_DEPENDENCIES = baseos-sdl3

SDL2_COMPAT_CONF_OPTS = \
	-DSDL2COMPAT_TESTS=OFF \
	-DSDL2COMPAT_STATIC=OFF \
	-DSDL2COMPAT_X11=OFF

$(eval $(cmake-package))
