################################################################################
#
# baseos-sdl3-image
#
################################################################################

BASEOS_SDL3_IMAGE_VERSION = 3.4.6
BASEOS_SDL3_IMAGE_SOURCE = SDL3_image-$(BASEOS_SDL3_IMAGE_VERSION).tar.gz
BASEOS_SDL3_IMAGE_SITE = https://www.libsdl.org/projects/SDL_image/release
BASEOS_SDL3_IMAGE_DL_SUBDIR = sdl3_image
BASEOS_SDL3_IMAGE_LICENSE = Zlib
BASEOS_SDL3_IMAGE_LICENSE_FILES = LICENSE.txt
BASEOS_SDL3_IMAGE_INSTALL_STAGING = YES
BASEOS_SDL3_IMAGE_DEPENDENCIES = baseos-sdl3 jpeg libpng webp

# Linked, not loaded at run time, so the rootfs checks see the libraries.
BASEOS_SDL3_IMAGE_CONF_OPTS = \
	-DSDLIMAGE_VENDORED=OFF \
	-DSDLIMAGE_STRICT=ON \
	-DSDLIMAGE_DEPS_SHARED=OFF \
	-DSDLIMAGE_SAMPLES=OFF \
	-DSDLIMAGE_BACKEND_STB=OFF \
	-DSDLIMAGE_AVIF=OFF \
	-DSDLIMAGE_JXL=OFF \
	-DSDLIMAGE_TIF=OFF

$(eval $(cmake-package))
