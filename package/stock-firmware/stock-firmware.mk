################################################################################
#
# stock-firmware
#
################################################################################

STOCK_FIRMWARE_VERSION = 20261015
STOCK_FIRMWARE_SOURCE = baseos-my355-prepared-$(STOCK_FIRMWARE_VERSION).tar.zst
STOCK_FIRMWARE_SITE = https://github.com/apommel/baseos-my355/releases/download/prepared-$(STOCK_FIRMWARE_VERSION)
STOCK_FIRMWARE_LICENSE = Proprietary
STOCK_FIRMWARE_REDISTRIBUTE = NO
STOCK_FIRMWARE_INSTALL_IMAGES = YES

define STOCK_FIRMWARE_INSTALL_TARGET_CMDS
	tar -xf $(@D)/stock-harvest.tar -C $(TARGET_DIR) \
		usr/lib/firmware/rtl8733bu_fw usr/lib/firmware/rtl8733bu_config
endef

define STOCK_FIRMWARE_INSTALL_IMAGES_CMDS
	$(INSTALL) -D -m 0644 $(@D)/uboot.img $(BINARIES_DIR)/vendor-uboot.img
endef

$(eval $(generic-package))
