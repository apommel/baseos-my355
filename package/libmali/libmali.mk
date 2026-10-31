################################################################################
#
# libmali
#
################################################################################

# build.sh pins the commit and mounts its sparse checkout here.
LIBMALI_VERSION = g29p1
LIBMALI_SITE = /src/libmali
LIBMALI_SITE_METHOD = local
LIBMALI_LICENSE = Proprietary
LIBMALI_LICENSE_FILES = END_USER_LICENCE_AGREEMENT.txt
LIBMALI_INSTALL_STAGING = YES
LIBMALI_DEPENDENCIES = libdrm
LIBMALI_PROVIDES = libegl libgles libgbm

LIBMALI_CONF_OPTS = \
	-Dgpu=bifrost-g52 \
	-Dlibrary=lib/aarch64-linux-gnu/libmali-bifrost-g52-g29p1.so \
	-Dopencl-icd=false \
	-Dkhr-header=true

# NextUI and its cores link the hook by stock's name. No OpenCL loader here,
# and no Wayland or X11 for the Vulkan layers.
define LIBMALI_STOCK_NAMES
	ln -sf libmali-hook.so.1 $(TARGET_DIR)/usr/lib/libmali_hook.so.1
	rm -f $(TARGET_DIR)/usr/lib/libOpenCL.so* $(TARGET_DIR)/usr/lib/libMaliOpenCL.so*
	rm -rf $(TARGET_DIR)/etc/OpenCL $(TARGET_DIR)/usr/share/vulkan/implicit_layer.d
endef
LIBMALI_POST_INSTALL_TARGET_HOOKS += LIBMALI_STOCK_NAMES

$(eval $(meson-package))
