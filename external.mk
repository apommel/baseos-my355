include $(sort $(wildcard $(BR2_EXTERNAL_BASEOS_PATH)/package/*/*.mk))

# rootfs-overlay/'s modetest wrapper maps stock's object ids, then runs this one.
define BASEOS_MODETEST_ASIDE
	mkdir -p $(TARGET_DIR)/usr/libexec
	mv $(TARGET_DIR)/usr/bin/modetest $(TARGET_DIR)/usr/libexec/modetest
endef
LIBDRM_POST_INSTALL_TARGET_HOOKS += BASEOS_MODETEST_ASIDE
