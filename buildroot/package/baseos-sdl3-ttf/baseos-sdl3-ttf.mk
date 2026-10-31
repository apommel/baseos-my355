################################################################################
#
# baseos-sdl3-ttf
#
################################################################################

BASEOS_SDL3_TTF_VERSION = 3.2.2
BASEOS_SDL3_TTF_SOURCE = SDL3_ttf-$(BASEOS_SDL3_TTF_VERSION).tar.gz
BASEOS_SDL3_TTF_SITE = https://www.libsdl.org/projects/SDL_ttf/release
BASEOS_SDL3_TTF_DL_SUBDIR = sdl3_ttf
BASEOS_SDL3_TTF_LICENSE = Zlib
BASEOS_SDL3_TTF_LICENSE_FILES = LICENSE.txt
BASEOS_SDL3_TTF_INSTALL_STAGING = YES
BASEOS_SDL3_TTF_DEPENDENCIES = baseos-sdl3 freetype harfbuzz host-pkgconf

BASEOS_SDL3_TTF_CONF_OPTS = \
	-DSDLTTF_VENDORED=OFF \
	-DSDLTTF_STRICT=ON \
	-DSDLTTF_SAMPLES=OFF \
	-DSDLTTF_HARFBUZZ=ON \
	-DSDLTTF_PLUTOSVG=OFF

$(eval $(cmake-package))
