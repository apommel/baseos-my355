################################################################################
#
# flipbase-tools
#
################################################################################

FLIPBASE_TOOLS_VERSION = local
FLIPBASE_TOOLS_SITE = $(BR2_EXTERNAL_FLIPBASE_PATH)/src
FLIPBASE_TOOLS_SITE_METHOD = local
FLIPBASE_TOOLS_LICENSE = MIT
FLIPBASE_TOOLS_DEPENDENCIES = freetype host-pkgconf

FLIPBASE_TOOLS_SBIN = gptgrow gptslot rebootmode pwrkeyd fatdirty wifibtd bootclock

define FLIPBASE_TOOLS_BUILD_CMDS
	$(foreach t,$(FLIPBASE_TOOLS_SBIN),\
		$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/$(t) $(@D)/$(t).c$(sep))
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/fbsplash $(@D)/fbsplash.c \
		$$($(PKG_CONFIG_HOST_BINARY) --cflags --libs freetype2)
endef

define FLIPBASE_TOOLS_INSTALL_TARGET_CMDS
	$(foreach t,$(FLIPBASE_TOOLS_SBIN),\
		$(INSTALL) -D -m 0755 $(@D)/$(t) $(TARGET_DIR)/usr/sbin/$(t)$(sep))
	$(INSTALL) -D -m 0755 $(@D)/fbsplash $(TARGET_DIR)/usr/bin/fbsplash
endef

$(eval $(generic-package))
