################################################################################
#
# flipbase-sdl3-image
#
################################################################################

FLIPBASE_SDL3_IMAGE_VERSION = 3.4.8
FLIPBASE_SDL3_IMAGE_SOURCE = SDL3_image-$(FLIPBASE_SDL3_IMAGE_VERSION).tar.gz
FLIPBASE_SDL3_IMAGE_SITE = https://www.libsdl.org/projects/SDL_image/release
FLIPBASE_SDL3_IMAGE_DL_SUBDIR = sdl3_image
FLIPBASE_SDL3_IMAGE_LICENSE = Zlib
FLIPBASE_SDL3_IMAGE_LICENSE_FILES = LICENSE.txt
FLIPBASE_SDL3_IMAGE_INSTALL_STAGING = YES
FLIPBASE_SDL3_IMAGE_DEPENDENCIES = flipbase-sdl3 jpeg libpng webp

# Linked, not loaded at run time, so the rootfs checks see the libraries.
FLIPBASE_SDL3_IMAGE_CONF_OPTS = \
	-DSDLIMAGE_VENDORED=OFF \
	-DSDLIMAGE_STRICT=ON \
	-DSDLIMAGE_DEPS_SHARED=OFF \
	-DSDLIMAGE_SAMPLES=OFF \
	-DSDLIMAGE_BACKEND_STB=OFF \
	-DSDLIMAGE_AVIF=OFF \
	-DSDLIMAGE_JXL=OFF \
	-DSDLIMAGE_TIF=OFF

$(eval $(cmake-package))
