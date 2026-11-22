################################################################################
#
# flipbase-tools
#
################################################################################

FLIPBASE_TOOLS_VERSION = local
FLIPBASE_TOOLS_SITE = $(BR2_EXTERNAL_FLIPBASE_PATH)/src
FLIPBASE_TOOLS_SITE_METHOD = local
FLIPBASE_TOOLS_LICENSE = MIT
# freetype for its unpacked sources: fbsplash builds its own copy in.
FLIPBASE_TOOLS_DEPENDENCIES = freetype

FLIPBASE_TOOLS_SBIN = gptgrow gptslot rebootmode pwrkeyd fatdirty wifibtd bootclock

# fbsplash runs from /init, where loading its shared libraries delayed the logo
# by ~50 ms: static, with only the FreeType modules a TrueType font needs.
FBSPLASH_FT_SRC = base/ftsystem.c base/ftinit.c base/ftdebug.c base/ftbase.c \
	base/ftbitmap.c base/ftmm.c sfnt/sfnt.c truetype/truetype.c smooth/smooth.c \
	autofit/autofit.c psnames/psnames.c

define FLIPBASE_TOOLS_BUILD_CMDS
	$(foreach t,$(FLIPBASE_TOOLS_SBIN),\
		$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/$(t) $(@D)/$(t).c$(sep))
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -static -o $(@D)/fbsplash $(@D)/fbsplash.c \
		$(addprefix $(FREETYPE_DIR)/src/,$(FBSPLASH_FT_SRC)) \
		-I$(@D) -I$(FREETYPE_DIR)/include -DFT2_BUILD_LIBRARY \
		'-DFT_CONFIG_MODULES_H="fbsplash-ftmodule.h"' '-DFT_CONFIG_OPTIONS_H="fbsplash-ftoption.h"' \
		-ffunction-sections -fdata-sections -Wl,--gc-sections
endef

define FLIPBASE_TOOLS_INSTALL_TARGET_CMDS
	$(foreach t,$(FLIPBASE_TOOLS_SBIN),\
		$(INSTALL) -D -m 0755 $(@D)/$(t) $(TARGET_DIR)/usr/sbin/$(t)$(sep))
	$(INSTALL) -D -m 0755 $(@D)/fbsplash $(TARGET_DIR)/usr/bin/fbsplash
endef

$(eval $(generic-package))
