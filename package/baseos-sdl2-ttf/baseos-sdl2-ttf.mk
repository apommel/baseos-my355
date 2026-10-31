################################################################################
#
# baseos-sdl2-ttf
#
################################################################################

BASEOS_SDL2_TTF_VERSION = 2.24.0
BASEOS_SDL2_TTF_SOURCE = SDL2_ttf-$(BASEOS_SDL2_TTF_VERSION).tar.gz
BASEOS_SDL2_TTF_SITE = http://www.libsdl.org/projects/SDL_ttf/release
BASEOS_SDL2_TTF_DL_SUBDIR = sdl2_ttf
BASEOS_SDL2_TTF_LICENSE = Zlib
BASEOS_SDL2_TTF_LICENSE_FILES = LICENSE.txt
BASEOS_SDL2_TTF_INSTALL_STAGING = YES
BASEOS_SDL2_TTF_DEPENDENCIES = sdl2-compat freetype host-pkgconf
BASEOS_SDL2_TTF_CONF_OPTS = \
	--disable-freetype-builtin \
	--disable-harfbuzz-builtin \
	--disable-harfbuzz \
	--without-x

$(eval $(autotools-package))
