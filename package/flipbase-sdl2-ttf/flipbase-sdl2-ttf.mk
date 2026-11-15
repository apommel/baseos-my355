################################################################################
#
# flipbase-sdl2-ttf
#
################################################################################

FLIPBASE_SDL2_TTF_VERSION = 2.24.0
FLIPBASE_SDL2_TTF_SOURCE = SDL2_ttf-$(FLIPBASE_SDL2_TTF_VERSION).tar.gz
FLIPBASE_SDL2_TTF_SITE = http://www.libsdl.org/projects/SDL_ttf/release
FLIPBASE_SDL2_TTF_DL_SUBDIR = sdl2_ttf
FLIPBASE_SDL2_TTF_LICENSE = Zlib
FLIPBASE_SDL2_TTF_LICENSE_FILES = LICENSE.txt
FLIPBASE_SDL2_TTF_INSTALL_STAGING = YES
FLIPBASE_SDL2_TTF_DEPENDENCIES = sdl2-compat freetype host-pkgconf
FLIPBASE_SDL2_TTF_CONF_OPTS = \
	--disable-freetype-builtin \
	--disable-harfbuzz-builtin \
	--disable-harfbuzz \
	--without-x

$(eval $(autotools-package))
