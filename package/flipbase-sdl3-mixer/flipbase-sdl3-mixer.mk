################################################################################
#
# flipbase-sdl3-mixer
#
################################################################################

FLIPBASE_SDL3_MIXER_VERSION = 3.2.4
FLIPBASE_SDL3_MIXER_SOURCE = SDL3_mixer-$(FLIPBASE_SDL3_MIXER_VERSION).tar.gz
FLIPBASE_SDL3_MIXER_SITE = https://www.libsdl.org/projects/SDL_mixer/release
FLIPBASE_SDL3_MIXER_LICENSE = Zlib
FLIPBASE_SDL3_MIXER_LICENSE_FILES = LICENSE.txt
FLIPBASE_SDL3_MIXER_INSTALL_STAGING = YES
FLIPBASE_SDL3_MIXER_DEPENDENCIES = flipbase-sdl3

# The codecs that need a library of their own are off.
FLIPBASE_SDL3_MIXER_CONF_OPTS = \
	-DSDLMIXER_VENDORED=OFF \
	-DSDLMIXER_STRICT=ON \
	-DSDLMIXER_TESTS=OFF \
	-DSDLMIXER_EXAMPLES=OFF \
	-DSDLMIXER_FLAC_LIBFLAC=OFF \
	-DSDLMIXER_GME=OFF \
	-DSDLMIXER_MOD=OFF \
	-DSDLMIXER_MP3_MPG123=OFF \
	-DSDLMIXER_MIDI_FLUIDSYNTH=OFF \
	-DSDLMIXER_OPUS=OFF \
	-DSDLMIXER_VORBIS_VORBISFILE=OFF \
	-DSDLMIXER_WAVPACK=OFF

$(eval $(cmake-package))
