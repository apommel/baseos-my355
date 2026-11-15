################################################################################
#
# flipbase-sdl3-ttf
#
################################################################################

FLIPBASE_SDL3_TTF_VERSION = 3.2.2
FLIPBASE_SDL3_TTF_SOURCE = SDL3_ttf-$(FLIPBASE_SDL3_TTF_VERSION).tar.gz
FLIPBASE_SDL3_TTF_SITE = https://www.libsdl.org/projects/SDL_ttf/release
FLIPBASE_SDL3_TTF_DL_SUBDIR = sdl3_ttf
FLIPBASE_SDL3_TTF_LICENSE = Zlib
FLIPBASE_SDL3_TTF_LICENSE_FILES = LICENSE.txt
FLIPBASE_SDL3_TTF_INSTALL_STAGING = YES
FLIPBASE_SDL3_TTF_DEPENDENCIES = flipbase-sdl3 freetype harfbuzz host-pkgconf

FLIPBASE_SDL3_TTF_CONF_OPTS = \
	-DSDLTTF_VENDORED=OFF \
	-DSDLTTF_STRICT=ON \
	-DSDLTTF_SAMPLES=OFF \
	-DSDLTTF_HARFBUZZ=ON \
	-DSDLTTF_PLUTOSVG=OFF

$(eval $(cmake-package))
