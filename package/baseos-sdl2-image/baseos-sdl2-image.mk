################################################################################
#
# baseos-sdl2-image
#
################################################################################

BASEOS_SDL2_IMAGE_VERSION = 2.8.12
BASEOS_SDL2_IMAGE_SOURCE = SDL2_image-$(BASEOS_SDL2_IMAGE_VERSION).tar.gz
BASEOS_SDL2_IMAGE_SITE = http://www.libsdl.org/projects/SDL_image/release
BASEOS_SDL2_IMAGE_DL_SUBDIR = sdl2_image
BASEOS_SDL2_IMAGE_INSTALL_STAGING = YES
BASEOS_SDL2_IMAGE_LICENSE = Zlib
BASEOS_SDL2_IMAGE_LICENSE_FILES = LICENSE.txt
BASEOS_SDL2_IMAGE_DEPENDENCIES = sdl2-compat jpeg libpng host-pkgconf

# stb_image would take PNG and JPEG over from the system libraries.
BASEOS_SDL2_IMAGE_CONF_OPTS = \
	--disable-sdltest \
	--disable-stb-image \
	--disable-avif \
	--disable-jxl \
	--disable-tif \
	--disable-webp

$(eval $(autotools-package))
